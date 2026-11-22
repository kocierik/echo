"""A closed conversation transcribed again whole: its words go back to its segments, and
a changed text sends the conversation to be analysed again."""

from datetime import datetime, timedelta, timezone

import httpx
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.models.conversation import Conversation
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.retranscription import GAP_SECONDS, split_words
from app.services.stt_base import STTResult, Word
from app.services.stt_deepgram import DeepgramSTTService
from app.workers import summaries
from tests.conftest import TEST_USER_ID, test_session

NOW = datetime.now(timezone.utc)


def test_each_word_goes_to_the_segment_it_was_said_in():
    spans = [(0.0, 2.0), (2.5, 5.0)]
    words = [
        Word("Since", 0.2, 0.5), Word("five", 0.6, 0.9), Word("years.", 1.0, 1.4),
        # In the pause between the two, nearer the second: to the second
        Word("I", 2.3, 2.45), Word("train.", 2.6, 3.0),
    ]

    assert split_words(words, spans) == ["Since five years.", "I train."]


class _Stt:
    provider, model = "deepgram", "nova-3"

    def __init__(self):
        self.calls = []

    async def transcribe(self, audio, **kwargs):
        self.calls.append(kwargs)
        # The first segment is ~1 s of audio (8000 bytes of ADPCM), then the pause
        second = 1.0 + GAP_SECONDS + 0.2
        return STTResult(
            text="Since five years. I train.", language="en",
            words=[
                Word("Since", 0.1, 0.3), Word("five", 0.4, 0.6), Word("years.", 0.6, 0.9),
                Word("I", second, second + 0.1), Word("train.", second + 0.2, second + 0.5),
            ],
        )


class _Redis:
    def __init__(self):
        self.queued = []

    async def set(self, key, value):
        pass

    async def lpush(self, queue, payload):
        self.queued.append((queue, payload))


async def _conversation(tmp_path, texts):
    async with test_session() as db:
        conversation = Conversation(
            user_id=TEST_USER_ID, started_at=NOW - timedelta(hours=1),
            ended_at=NOW - timedelta(minutes=30), analysis_status="completed",
        )
        db.add(conversation)
        await db.flush()
        for i, text in enumerate(texts):
            audio = tmp_path / f"{i}.adpcm"
            audio.write_bytes(b"\x11" * 8000)  # ~1 s at 16 kHz, 4 bits a sample
            segment = Segment(
                user_id=TEST_USER_ID, conversation_id=conversation.id,
                received_at=NOW - timedelta(minutes=30),
                recorded_at=NOW - timedelta(minutes=40 - i),
                duration_ms=1000, audio_path=str(audio), speaker="self",
                transcription_status="completed",
            )
            db.add(segment)
            await db.flush()
            db.add(Transcription(
                segment_id=segment.id, text=text, language="en",
                stt_provider="deepgram", stt_model="nova-3",
            ))
        await db.commit()
        return conversation.id


async def test_a_closed_conversation_is_transcribed_again_and_analysed_again(tmp_path):
    conversation_id = await _conversation(tmp_path, ["[You] Siems five years.", "[You] Train."])
    stt, redis = _Stt(), _Redis()

    again = await summaries.close_conversations(
        redis, now=NOW, session_factory=test_session, stt=stt
    )

    assert again == 1 and len(stt.calls) == 1
    async with test_session() as db:
        texts = list(await db.scalars(
            select(Transcription.text).join(Segment)
            .where(Segment.conversation_id == conversation_id).order_by(Segment.recorded_at)
        ))
        conversation = await db.get(Conversation, conversation_id)
    assert texts == ["[You] Since five years.", "[You] I train."]
    assert conversation.retranscribed_at is not None
    assert conversation.analysis_status == "reprocessing"
    assert redis.queued[0][0] == "queue:reanalysis"
    assert str(conversation_id) in redis.queued[0][1]

    # Done once: the next run leaves it
    assert await summaries.close_conversations(
        redis, now=NOW, session_factory=test_session, stt=stt
    ) == 0
    assert len(stt.calls) == 1


async def test_one_short_segment_is_not_transcribed_again_but_is_analysed(tmp_path):
    """Nothing to gain from transcribing it again; its entities, summary and facts still
    come from the analysis of the closed conversation, as for any other."""
    conversation_id = await _conversation(tmp_path, ["[You] Ciao."])
    stt, redis = _Stt(), _Redis()

    closed = await summaries.close_conversations(
        redis, now=NOW, session_factory=test_session, stt=stt
    )

    async with test_session() as db:
        conversation = await db.get(Conversation, conversation_id)
    assert closed == 1 and stt.calls == []
    assert conversation.retranscribed_at is not None
    assert conversation.analysis_status == "reprocessing"
    assert str(conversation_id) in redis.queued[0][1]


async def test_a_conversation_whose_speech_is_still_arriving_is_not_closed_yet(tmp_path):
    """The card's backlog: said an hour ago, its segments reach the server only now."""
    conversation_id = await _conversation(tmp_path, ["[You] Siems five years.", "[You] Train."])
    async with test_session() as db:
        latest = (await db.scalars(
            select(Segment).where(Segment.conversation_id == conversation_id)
        )).first()
        latest.received_at = NOW - timedelta(seconds=30)
        await db.commit()
    stt, redis = _Stt(), _Redis()

    assert await summaries.close_conversations(
        redis, now=NOW, session_factory=test_session, stt=stt
    ) == 0
    # Quiet for the silence timeout since the last arrival: closed
    later = NOW + timedelta(minutes=10)
    assert await summaries.close_conversations(
        redis, now=later, session_factory=test_session, stt=stt
    ) == 1


async def test_without_retranscription_a_closed_conversation_is_still_analysed(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(summaries.settings, "conversation_retranscription", False)
    conversation_id = await _conversation(tmp_path, ["[You] Siems five years.", "[You] Train."])
    stt, redis = _Stt(), _Redis()

    closed = await summaries.close_conversations(
        redis, now=NOW, session_factory=test_session, stt=stt
    )

    assert closed == 1 and stt.calls == []
    assert str(conversation_id) in redis.queued[0][1]


async def test_deepgram_asked_who_said_each_word():
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200, json={"results": {"channels": [{"alternatives": [{
            "transcript": "Ciao. Ciao.",
            "words": [
                {"word": "ciao", "punctuated_word": "Ciao.", "start": 0.1, "end": 0.4,
                 "speaker": 0},
                {"word": "ciao", "punctuated_word": "Ciao.", "start": 0.6, "end": 0.9,
                 "speaker": 1},
            ],
        }]}]}})

    service = DeepgramSTTService(transport=httpx.MockTransport(handler))

    result = await service.transcribe(b"wav", diarize=True)

    assert seen[0].url.params["diarize"] == "true"
    assert [w.speaker for w in result.words] == [0, 1]


def _axis(i: int) -> list[float]:
    v = [0.0] * 256
    v[i] = 1.0
    return v


async def test_several_voices_in_a_segment_are_its_turns(
    tmp_path, monkeypatch, client, auth_headers
):
    """Me and a stranger in the first segment, a third voice alone in the second."""
    from app.models.voice_profile import VoiceProfile
    from app.services import retranscription

    conversation_id = await _conversation(tmp_path, ["[You] Ciao come.", "[Others] Io pure."])
    async with test_session() as db:
        me = VoiceProfile(user_id=TEST_USER_ID, name="You", is_self=True,
                          embedding=_axis(0), sample_count=3)
        db.add(me)
        second = (await db.scalars(
            select(Segment).where(Segment.conversation_id == conversation_id)
            .order_by(Segment.recorded_at.desc())
        )).first()
        second.speaker = "other"
        await db.commit()
        me_id = str(me.id)

    voices = iter([_axis(0), _axis(1), _axis(2)])  # speakers 0, 1, 2 in that order

    async def embed(_wav):
        return next(voices)

    monkeypatch.setattr(retranscription, "embed_voice", embed)
    second_start = 1.0 + GAP_SECONDS

    class _Diarized(_Stt):
        async def transcribe(self, audio, **kwargs):
            self.calls.append(kwargs)
            return STTResult(text="", language="it", words=[
                Word("Ciao", 0.1, 0.3, 0), Word("come", 0.4, 0.5, 0), Word("Bene", 0.6, 0.9, 1),
                Word("Io", second_start + 0.1, second_start + 0.3, 2),
                Word("pure.", second_start + 0.4, second_start + 0.7, 2),
            ])

    stt = _Diarized()
    await summaries.close_conversations(
        _Redis(), now=NOW, session_factory=test_session, stt=stt
    )

    assert stt.calls[0]["diarize"] is True
    async with test_session() as db:
        first, second = list(await db.scalars(
            select(Segment).options(selectinload(Segment.transcription))
            .where(Segment.conversation_id == conversation_id).order_by(Segment.recorded_at)
        ))
    assert [(t["speaker"], t["profile_id"], t["group"]) for t in first.transcription.turns] == [
        ("self", me_id, None), ("other", None, 2),
    ]
    assert second.transcription.turns is None and second.voice_group == 3

    body = (await client.get(f"/api/conversations/{conversation_id}", headers=auth_headers)).json()
    turns = body["transcriptions"][0]["turns"]
    assert [(t["speaker_label"], t["speaker_name"]) for t in turns] == [
        ("self", "You"), ("other", "Person 2"),
    ]
    assert turns[0]["text"].startswith("Ciao") and "Bene" in turns[1]["text"]
    assert body["transcriptions"][1]["speaker_name"] == "Person 3"


async def test_only_the_closest_voice_is_the_user(tmp_path, monkeypatch):
    """Through the pendant everyone sounds ~0.85 like the user: of two voices in a
    conversation only the closer is "You", though live both segments said "You"."""
    import math

    from app.models.voice_profile import VoiceProfile
    from app.services import retranscription

    conversation_id = await _conversation(tmp_path, ["[You] Ciao.", "[You] Ciao a te."])
    async with test_session() as db:
        db.add(VoiceProfile(user_id=TEST_USER_ID, name="You", is_self=True,
                            embedding=_axis(0), sample_count=3))
        await db.commit()

    alike = _axis(0)
    alike[0], alike[1] = 0.85, math.sqrt(1 - 0.85**2)
    voices = iter([_axis(0), alike])

    async def embed(_wav):
        return next(voices)

    monkeypatch.setattr(retranscription, "embed_voice", embed)
    second_start = 1.0 + GAP_SECONDS

    class _Two(_Stt):
        async def transcribe(self, audio, **kwargs):
            return STTResult(text="", language="it", words=[
                Word("Ciao.", 0.1, 0.5, 0),
                Word("Ciao", second_start + 0.1, second_start + 0.3, 1),
                Word("a", second_start + 0.3, second_start + 0.4, 1),
                Word("te.", second_start + 0.4, second_start + 0.6, 1),
            ])

    await summaries.close_conversations(
        _Redis(), now=NOW, session_factory=test_session, stt=_Two()
    )

    async with test_session() as db:
        rows = (await db.execute(
            select(Segment.speaker, Transcription.text).join(Transcription)
            .where(Segment.conversation_id == conversation_id).order_by(Segment.recorded_at)
        )).all()
    assert [tuple(r) for r in rows] == [("self", "[You] Ciao."), ("other", "[Others] Ciao a te.")]


async def test_a_segment_with_several_voices_is_split_as_soon_as_it_is_transcribed(monkeypatch):
    """Live, before the conversation closes: me, then two voices nobody named. They are
    told apart, but not numbered: "Person 2" needs the whole conversation."""
    from app.models.voice_profile import VoiceProfile
    from app.services import retranscription

    async with test_session() as db:
        me = VoiceProfile(user_id=TEST_USER_ID, name="You", is_self=True,
                          embedding=_axis(0), sample_count=3)
        db.add(me)
        await db.commit()
        me_id = str(me.id)

        voices = iter([_axis(0), _axis(1), _axis(2)])

        async def embed(_wav):
            return next(voices)

        monkeypatch.setattr(retranscription, "embed_voice", embed)
        segment = Segment(user_id=TEST_USER_ID, speaker="self")
        words = [
            Word("Hai", 0.1, 0.3, 0), Word("i", 0.3, 0.4, 0), Word("numeri?", 0.4, 0.8, 0),
            Word("Sì.", 1.0, 1.3, 1), Word("Eccoli.", 1.5, 1.9, 2),
        ]

        turns = await retranscription.segment_turns(db, segment, words, b"\0" * 64000)
        one_voice = await retranscription.segment_turns(
            db, segment, [Word("Ciao.", 0.1, 0.4, 0)], b"\0" * 64000
        )

    assert [(t["speaker"], t["profile_id"], t["group"], t["text"]) for t in turns] == [
        ("self", me_id, None, "Hai i numeri?"),
        ("other", None, None, "Sì."),
        ("other", None, None, "Eccoli."),
    ]
    assert one_voice is None


def _long_words(speaker: int = 0) -> list[Word]:
    """Six words of 4 s each: six windows, heard by the speech-to-text as one voice."""
    return [Word(f"w{i}", i * 4.0, i * 4.0 + 4.0, speaker) for i in range(6)]


async def test_one_voice_to_the_speech_to_text_but_two_to_the_fingerprints(monkeypatch):
    """Deepgram heard one voice; the windows' fingerprints fall into two opposite voices:
    me for the first three windows, a stranger for the last three."""
    from app.models.voice_profile import VoiceProfile
    from app.services import retranscription

    other = [-0.6 * x + 0.8 * y for x, y in zip(_axis(0), _axis(1))]
    async with test_session() as db:
        me = VoiceProfile(user_id=TEST_USER_ID, name="You", is_self=True,
                          embedding=_axis(0), sample_count=3)
        db.add(me)
        await db.commit()
        me_id = str(me.id)
        # Six windows, then each of the two voices from all it said
        voices = iter([_axis(0)] * 3 + [other] * 3 + [_axis(0), other])

        async def embed(_wav):
            return next(voices)

        monkeypatch.setattr(retranscription, "embed_voice", embed)
        segment = Segment(user_id=TEST_USER_ID, speaker="self")
        turns = await retranscription.segment_turns(db, segment, _long_words(), b"\1" * 900_000)

    assert [(t["speaker"], t["profile_id"], t["text"]) for t in turns] == [
        ("self", me_id, "W0 w1 w2"), ("other", None, "W3 w4 w5"),
    ]


async def test_one_voice_throughout_stays_one_voice(monkeypatch):
    from app.services import retranscription

    alike = [iter([_axis(0), _axis(0), _axis(1)] * 2)]

    async def embed(_wav):
        return next(alike[0])

    monkeypatch.setattr(retranscription, "embed_voice", embed)
    async with test_session() as db:
        segment = Segment(user_id=TEST_USER_ID, speaker="self")
        # Two groups at most orthogonal (0): not below the threshold, no split
        assert await retranscription.segment_turns(
            db, segment, _long_words(), b"\1" * 900_000
        ) is None


async def test_a_short_segment_is_not_split_by_fingerprints(monkeypatch):
    from app.services import retranscription

    async def embed(_wav):
        raise AssertionError("no fingerprint for fewer than three windows")

    monkeypatch.setattr(retranscription, "embed_voice", embed)
    async with test_session() as db:
        segment = Segment(user_id=TEST_USER_ID, speaker="self")
        assert await retranscription.segment_turns(
            db, segment, _long_words()[:2], b"\1" * 300_000
        ) is None


def test_the_most_different_split_follows_the_voices():
    from app.services.retranscription import most_different_split

    a = _axis(0)
    b = [-0.6 * x + 0.8 * y for x, y in zip(_axis(0), _axis(1))]
    similarity, groups = most_different_split([a, b, a, b])
    assert abs(similarity + 0.6) < 1e-6
    assert groups[0] == groups[2] != groups[1] == groups[3]
