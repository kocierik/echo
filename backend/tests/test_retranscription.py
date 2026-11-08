"""A closed conversation transcribed again whole: its words go back to its segments, and
a changed text sends the conversation to be analysed again."""

from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.models.conversation import Conversation
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.retranscription import GAP_SECONDS, split_words
from app.services.stt_base import STTResult, Word
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
                received_at=NOW, recorded_at=NOW - timedelta(minutes=40 - i),
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

    again = await summaries.retranscribe_closed_conversations(
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
    assert await summaries.retranscribe_closed_conversations(
        redis, now=NOW, session_factory=test_session, stt=stt
    ) == 0
    assert len(stt.calls) == 1


async def test_one_segment_is_left_as_it_is_and_marked_done(tmp_path):
    conversation_id = await _conversation(tmp_path, ["[You] Ciao."])
    stt, redis = _Stt(), _Redis()

    again = await summaries.retranscribe_closed_conversations(
        redis, now=NOW, session_factory=test_session, stt=stt
    )

    async with test_session() as db:
        conversation = await db.get(Conversation, conversation_id)
    assert again == 0 and stt.calls == [] and redis.queued == []
    assert conversation.retranscribed_at is not None
    assert conversation.analysis_status == "completed"
