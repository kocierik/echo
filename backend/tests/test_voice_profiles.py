"""Who is speaking: own voice enrollment, naming voices, recognition and deletion."""

import math
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Segment, Transcription, VoiceProfile
from app.services import voice_profiles as voices
from app.services.voice_embedding import cosine, normalize
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation, make_entity

DIM = 256


def axis(i: int) -> list[float]:
    v = [0.0] * DIM
    v[i] = 1.0
    return v


def near(i: int, j: int, similarity: float) -> list[float]:
    """A unit vector with `similarity` to axis i, the rest towards axis j."""
    v = [0.0] * DIM
    v[i] = similarity
    v[j] = math.sqrt(1 - similarity**2)
    return v


ME, MARCO, STRANGER = 0, 1, 2


def _profile(index: int, *, is_self=False, name="Marco") -> VoiceProfile:
    return VoiceProfile(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        name="You" if is_self else name,
        is_self=is_self,
        embedding=axis(index),
        sample_count=3,
    )


def test_running_mean_and_normalization():
    profile = _profile(ME, is_self=True)
    profile.sample_count = 1
    voices.add_sample(profile, axis(MARCO))
    assert profile.sample_count == 2
    assert math.isclose(cosine(profile.embedding, normalize([1, 1] + [0] * 254)), 1.0)


def test_recognition_by_similarity():
    me, marco = _profile(ME, is_self=True), _profile(MARCO)
    segment = Segment()

    assert voices.recognize(segment, near(ME, STRANGER, 0.8), [me, marco]) == "self"
    assert segment.voice_profile_id == me.id and segment.voice_match == "auto"

    segment = Segment()
    assert voices.recognize(segment, near(MARCO, STRANGER, 0.7), [me, marco]) == "other"
    assert (segment.voice_profile_id, segment.voice_match) == (marco.id, "auto")

    segment = Segment()  # nearly Marco: the transcript asks
    assert voices.recognize(segment, near(MARCO, STRANGER, 0.5), [me, marco]) == "other"
    assert (segment.voice_profile_id, segment.voice_match) == (marco.id, "suggested")

    segment = Segment()  # nobody known, but the user's voice is: someone else
    assert voices.recognize(segment, axis(STRANGER), [me, marco]) == "other"
    assert segment.voice_profile_id is None

    # Without the user's own voice the energy rule decides, unless a voice is sure
    assert voices.recognize(Segment(), axis(STRANGER), [marco]) is None
    assert voices.recognize(Segment(), near(MARCO, STRANGER, 0.9), [marco]) == "other"


def test_a_voice_between_two_profiles_is_neither():
    me, marco = _profile(ME, is_self=True), _profile(MARCO)
    between = normalize([0.8, 0.75] + [0.0] * (DIM - 2))  # ~0.73 to me, ~0.68 to Marco

    segment = Segment()
    assert voices.recognize(segment, between, [me, marco]) == "other"
    assert segment.voice_profile_id is None and segment.voice_match is None


def test_a_fingerprint_is_taken_where_someone_speaks():
    from array import array

    from app.services.voice_embedding import loudest_frames

    quiet, loud = array("h", [10] * 320).tobytes(), array("h", [8000] * 320).tobytes()
    pcm = quiet * 6 + loud * 4

    assert loudest_frames(pcm) == loud * 4
    assert loudest_frames(b"") == b""


def test_retag_replaces_the_speaker_tag():
    assert voices.retag("[Others] ciao", "self") == "[You] ciao"
    assert voices.retag("[Tu] ciao", "other") == "[Others] ciao"
    assert voices.retag("ciao", "self") == "[You] ciao"


async def _segments(db: AsyncSession, started_at, texts, embeddings):
    conversation, transcriptions = await make_conversation(
        db, started_at=started_at, texts=texts
    )
    segments = []
    for transcription, embedding in zip(transcriptions, embeddings):
        segment = await db.get(Segment, transcription.segment_id)
        segment.voice_embedding = embedding
        segment.speaker = "other"
        transcription.speaker_label = "other"
        segments.append(segment)
    await db.commit()
    return conversation, segments


@pytest.mark.asyncio
async def test_enrolling_the_own_voice(db_session: AsyncSession):
    start = datetime.now(timezone.utc) - timedelta(minutes=5)
    _, segments = await _segments(
        db_session,
        start,
        ("[Others] Leggo il testo.", "[Others] Ancora il testo."),
        [near(ME, STRANGER, 0.95), near(ME, MARCO, 0.95)],
    )

    result = await voices.enroll_self(
        db_session, TEST_USER_ID, start - timedelta(seconds=1), start + timedelta(minutes=1)
    )

    assert result.status == "done" and result.segments == 2
    assert result.profile.is_self and result.profile.sample_count == 2
    assert cosine(result.profile.embedding, axis(ME)) > 0.95
    transcription = (
        await db_session.execute(
            select(Transcription).where(Transcription.segment_id == segments[0].id)
        )
    ).scalar_one()
    assert transcription.text == "[You] Leggo il testo."
    assert transcription.speaker_label == "self"
    assert (await db_session.get(Segment, segments[0].id)).voice_match == "confirmed"


@pytest.mark.asyncio
async def test_enrollment_takes_a_long_segment_that_began_before_the_reading(
    db_session: AsyncSession,
):
    """Firmware 0.8.2 on: a 25 s segment starts before Start is tapped."""
    start = datetime.now(timezone.utc) - timedelta(minutes=5)
    _, [before, _] = await _segments(
        db_session, start, ("[Others] Leggo.", "[Others] Altro."),
        [near(ME, STRANGER, 0.95), near(ME, MARCO, 0.95)],
    )
    before.duration_ms = 25000  # start .. start+25 s; the second one at start+10 s, 5 s
    await db_session.commit()

    # Reading from start+16 s to start+30 s: 9 s of the first, nothing of the second
    result = await voices.enroll_self(
        db_session, TEST_USER_ID, start + timedelta(seconds=16), start + timedelta(seconds=30)
    )

    assert result.status == "done" and result.segments == 1


@pytest.mark.asyncio
async def test_enrollment_waits_for_a_segment_still_on_its_way(db_session: AsyncSession):
    start = datetime.now(timezone.utc)

    result = await voices.enroll_self(
        db_session, TEST_USER_ID, start - timedelta(seconds=20), start
    )

    assert result.status == "waiting"


@pytest.mark.asyncio
async def test_enrollment_waits_for_transcription_or_finds_no_speech(db_session: AsyncSession):
    start = datetime.now(timezone.utc)
    await make_conversation(db_session, started_at=start, texts=(None,))
    await db_session.commit()

    waiting = await voices.enroll_self(
        db_session, TEST_USER_ID, start - timedelta(seconds=1), start + timedelta(seconds=30)
    )
    assert waiting.status == "waiting"

    later = start + timedelta(minutes=10)
    none = await voices.enroll_self(
        db_session, TEST_USER_ID, start - timedelta(seconds=1), start + timedelta(seconds=30),
        now=later,
    )
    assert none.status == "no_speech"


@pytest.mark.asyncio
async def test_naming_a_voice_links_the_person_and_labels_the_conversation(
    client, auth_headers, db_session: AsyncSession
):
    start = datetime.now(timezone.utc) - timedelta(hours=1)
    conversation, segments = await _segments(
        db_session,
        start,
        ("[Others] Ti mando il preventivo.", "[Others] Arriva lunedì.", "[Others] Io no."),
        [near(MARCO, STRANGER, 0.97), near(MARCO, ME, 0.9), axis(STRANGER)],
    )
    marco = make_entity(conversation, "person", "Marco Rossi")
    db_session.add(marco)
    await db_session.commit()

    response = await client.post(
        f"/api/segments/{segments[0].id}/voice",
        headers=auth_headers,
        json={"person_id": str(marco.id)},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["profile"]["name"] == "Marco Rossi"
    assert body["profile"]["person_id"] == str(marco.id)
    assert body["relabelled"] == 1 and body["learned"] is True

    detail = (
        await client.get(f"/api/conversations/{conversation.id}", headers=auth_headers)
    ).json()
    named = [(t["speaker_name"], t["voice_match"]) for t in detail["transcriptions"]]
    assert named == [("Marco Rossi", "confirmed"), ("Marco Rossi", "auto"), (None, None)]

    # The same name again refines the same profile
    again = await client.post(
        f"/api/segments/{segments[2].id}/voice",
        headers=auth_headers,
        json={"name": "marco rossi"},
    )
    assert again.json()["profile"]["id"] == body["profile"]["id"]
    assert again.json()["profile"]["sample_count"] == 2


@pytest.mark.asyncio
async def test_naming_a_new_voice_saves_that_person(
    client, auth_headers, db_session: AsyncSession
):
    """Naming a voice is the user saving a person: they are in People from then on, and
    a voice named before they were is theirs."""
    start = datetime.now(timezone.utc) - timedelta(hours=1)
    _, segments = await _segments(
        db_session, start, ("[Others] Ciao.", "[Others] A dopo."),
        [near(MARCO, STRANGER, 0.97), near(MARCO, ME, 0.9)],
    )
    # A voice named "Giulia" before this: no person with it
    earlier = _profile(STRANGER, name="Giulia")
    db_session.add(earlier)
    await db_session.commit()
    earlier_id = earlier.id

    named = await client.post(
        f"/api/segments/{segments[0].id}/voice", headers=auth_headers, json={"name": "Marco"}
    )
    linked = await client.post(
        f"/api/segments/{segments[1].id}/voice", headers=auth_headers, json={"name": "giulia"}
    )

    people = (await client.get("/api/people", headers=auth_headers)).json()
    assert sorted(person["name"] for person in people) == ["Giulia", "Marco"]
    by_name = {person["name"]: person["id"] for person in people}
    assert named.json()["profile"]["person_id"] == by_name["Marco"]
    assert linked.json()["profile"]["id"] == str(earlier_id)
    assert linked.json()["profile"]["person_id"] == by_name["Giulia"]


@pytest.mark.asyncio
async def test_naming_one_turn_teaches_that_voice_and_finds_its_other_turns(
    client, auth_headers, db_session: AsyncSession
):
    """Two people in one segment: the user says who the second block is. That voice is
    learned from that block alone, and its other blocks take the name; mine do not."""
    start = datetime.now(timezone.utc) - timedelta(hours=1)
    conversation, segments = await _segments(
        db_session, start, ("[You] Hai i numeri? Sì.", "[You] Eccoli. Grazie."),
        [near(ME, MARCO, 0.8), near(ME, MARCO, 0.8)],
    )
    db_session.add(_profile(ME, is_self=True))

    def turn(text, voice, speaker="other"):
        return {"speaker": speaker, "profile_id": None, "group": None, "text": text,
                "embedding": voice}

    first = (await db_session.execute(
        select(Transcription).where(Transcription.segment_id == segments[0].id)
    )).scalar_one()
    second = (await db_session.execute(
        select(Transcription).where(Transcription.segment_id == segments[1].id)
    )).scalar_one()
    first.turns = [
        turn("Hai i numeri?", near(ME, STRANGER, 0.97), "self"),
        turn("Sì.", near(MARCO, STRANGER, 0.97)),
    ]
    second.turns = [
        turn("Eccoli.", near(MARCO, ME, 0.95)),
        turn("Grazie.", near(ME, MARCO, 0.95), "self"),
        turn("Ciao.", axis(STRANGER)),
    ]
    await db_session.commit()

    named = await client.post(
        f"/api/segments/{segments[0].id}/voice", headers=auth_headers,
        json={"name": "Marco", "turn": 1},
    )
    missing = await client.post(
        f"/api/segments/{segments[0].id}/voice", headers=auth_headers,
        json={"name": "Marco", "turn": 7},
    )

    assert named.status_code == 200 and missing.status_code == 404
    assert named.json()["learned"] is True and named.json()["relabelled"] == 1
    detail = (
        await client.get(f"/api/conversations/{conversation.id}", headers=auth_headers)
    ).json()
    blocks = [
        [(t["speaker_label"], t["speaker_name"]) for t in line["turns"]]
        for line in detail["transcriptions"]
    ]
    assert blocks == [
        [("self", None), ("other", "Marco")],
        [("other", "Marco"), ("self", None), ("other", None)],
    ]
    # In People too: naming a voice is saving that person
    people = (await client.get("/api/people", headers=auth_headers)).json()
    assert [person["name"] for person in people] == ["Marco"]


@pytest.mark.asyncio
async def test_naming_a_turn_skips_segments_whose_turns_were_cleared(
    client, auth_headers, db_session: AsyncSession
):
    # Cleared turns were once written as JSON null, which `turns IS NOT NULL` lets
    # through: naming a voice then failed on the whole conversation
    from sqlalchemy import text

    start = datetime.now(timezone.utc) - timedelta(hours=1)
    conversation, segments = await _segments(
        db_session, start, ("[You] Hai i numeri? Sì.", "[You] Va bene."),
        [near(ME, MARCO, 0.8), near(ME, MARCO, 0.8)],
    )
    first = (await db_session.execute(
        select(Transcription).where(Transcription.segment_id == segments[0].id)
    )).scalar_one()
    first.turns = [
        {"speaker": "self", "profile_id": None, "group": None, "text": "Hai i numeri?",
         "embedding": near(ME, STRANGER, 0.97)},
        {"speaker": "other", "profile_id": None, "group": None, "text": "Sì.",
         "embedding": near(MARCO, STRANGER, 0.97)},
    ]
    await db_session.commit()
    await db_session.execute(
        text("UPDATE transcriptions SET turns = 'null'::jsonb WHERE segment_id = :id"),
        {"id": segments[1].id},
    )
    await db_session.commit()

    named = await client.post(
        f"/api/segments/{segments[0].id}/voice", headers=auth_headers,
        json={"name": "Marco", "turn": 1},
    )

    assert named.status_code == 200


@pytest.mark.asyncio
async def test_a_segment_without_fingerprint_cannot_start_a_profile(
    client, auth_headers, db_session: AsyncSession
):
    _, transcriptions = await make_conversation(
        db_session, started_at=datetime.now(timezone.utc), texts=("[Others] Vecchio.",)
    )
    await db_session.commit()

    response = await client.post(
        f"/api/segments/{transcriptions[0].segment_id}/voice",
        headers=auth_headers,
        json={"name": "Ada"},
    )
    assert response.status_code == 422
    missing = await client.post(
        f"/api/segments/{uuid.uuid4()}/voice", headers=auth_headers, json={"is_self": True}
    )
    assert missing.status_code == 404


@pytest.mark.asyncio
async def test_rejecting_a_suggestion_and_deleting_a_voice(
    client, auth_headers, db_session: AsyncSession
):
    start = datetime.now(timezone.utc) - timedelta(hours=2)
    _, segments = await _segments(
        db_session, start, ("[Others] Forse Marco.",), [near(MARCO, STRANGER, 0.5)]
    )
    marco = _profile(MARCO)
    db_session.add(marco)
    await db_session.flush()
    segments[0].voice_profile_id = marco.id
    segments[0].voice_match = "suggested"
    await db_session.commit()

    rejected = await client.post(
        f"/api/segments/{segments[0].id}/voice/reject", headers=auth_headers
    )
    assert rejected.status_code == 204
    await db_session.refresh(segments[0])
    assert segments[0].voice_profile_id is None and segments[0].voice_match is None

    listed = (await client.get("/api/voice-profiles", headers=auth_headers)).json()
    assert listed["fingerprints_enabled"] is False  # no model in tests
    assert [p["name"] for p in listed["items"]] == ["Marco"]

    deleted = await client.delete(f"/api/voice-profiles/{marco.id}", headers=auth_headers)
    assert deleted.status_code == 204
    assert (await client.get("/api/voice-profiles", headers=auth_headers)).json()["items"] == []


@pytest.mark.asyncio
async def test_a_correction_to_you_teaches_the_own_voice(
    client, auth_headers, db_session: AsyncSession
):
    _, segments = await _segments(
        db_session,
        datetime.now(timezone.utc) - timedelta(hours=3),
        ("[Others] Questo l'ho detto io.",),
        [near(ME, STRANGER, 0.99)],
    )

    response = await client.patch(
        f"/api/segments/{segments[0].id}/transcription",
        headers=auth_headers,
        json={"text": "Questo l'ho detto io.", "speaker": "self"},
    )

    assert response.status_code in (200, 202)
    profile = (
        await db_session.execute(select(VoiceProfile).where(VoiceProfile.is_self))
    ).scalar_one()
    assert profile.sample_count == 1
    assert cosine(profile.embedding, axis(ME)) > 0.98


def test_unknown_voices_are_grouped_by_their_fingerprints():
    marco, anna, luca = axis(MARCO), axis(STRANGER), axis(3)

    groups = voices.group_voices(
        [marco, anna, near(MARCO, STRANGER, 0.95), luca, anna], threshold=0.6
    )

    assert groups == [0, 1, 0, 2, 1]


@pytest.mark.asyncio
async def test_three_people_are_three_voices_not_one(
    client, auth_headers, db_session: AsyncSession
):
    """Every unknown voice was "Others": told apart as Person 2, Person 3."""
    start = datetime.now(timezone.utc) - timedelta(hours=1)
    conversation, _ = await _segments(
        db_session,
        start,
        ("[Others] Ciao.", "[Others] Io sono Anna.", "[Others] Sì, ciao Anna."),
        [axis(MARCO), axis(STRANGER), near(MARCO, ME, 0.95)],
    )
    alone, _ = await _segments(
        db_session, start + timedelta(minutes=30), ("[Others] Pronto?",), [axis(3)]
    )

    assert await voices.number_unknown_voices(db_session, conversation.id) == 2
    assert await voices.number_unknown_voices(db_session, alone.id) == 1
    await db_session.commit()

    detail = (
        await client.get(f"/api/conversations/{conversation.id}", headers=auth_headers)
    ).json()
    assert [t["speaker_name"] for t in detail["transcriptions"]] == [
        "Person 2", "Person 3", "Person 2",
    ]
    single = (await client.get(f"/api/conversations/{alone.id}", headers=auth_headers)).json()
    assert single["transcriptions"][0]["speaker_name"] is None
