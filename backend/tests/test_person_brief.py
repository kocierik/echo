"""Who is in front of you: a known voice speaks, the phone says what is worth knowing."""

import asyncio
import json
import uuid
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import user_zone
from app.models import Entity, Segment, VoiceProfile
from app.services import notice_ledger as ledger
from app.services import person_brief as pb
from app.services.device_commands import DEVICE_COMMANDS_KEY
from app.services.notifications import Notice
from app.services.transcription_enhancer import STTContext
from app.workers import stt as stt_worker
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation
from tests.fakes.redis import InMemoryRedis

TODAY = date(2026, 10, 15)
NOW = datetime(2026, 10, 15, 11, tzinfo=user_zone())


def _segment(recorded_at=NOW - timedelta(seconds=20), **fields) -> Segment:
    return Segment(id=uuid.uuid4(), user_id=TEST_USER_ID, recorded_at=recorded_at, **fields)


def _profile(person=None, *, name="Marco", is_self=False) -> VoiceProfile:
    return VoiceProfile(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        name=name,
        is_self=is_self,
        person_id=person.id if person is not None else None,
        embedding=[1.0],
        sample_count=3,
    )


def _commands(redis) -> list[dict]:
    key = DEVICE_COMMANDS_KEY.format(user_id=TEST_USER_ID)
    return [json.loads(c) for c in redis.lists.get(key, [])]


async def _marco(db: AsyncSession, *, with_promise=True) -> Entity:
    conversation, _ = await make_conversation(
        db, started_at=NOW - timedelta(days=2), title="Atlas launch", texts=()
    )
    marco = Entity(
        user_id=TEST_USER_ID, entity_type="person", name="Marco Rossi",
        conversation_id=conversation.id,
    )
    db.add(marco)
    if with_promise:
        db.add(Entity(
            user_id=TEST_USER_ID, entity_type="task", name="Send the quote",
            metadata_={"promise": True, "done": False, "promise_to": "Marco"},
        ))
    await db.commit()
    return marco


def test_confident_voice_only():
    me = _profile(name="You", is_self=True)
    marco = _profile()
    profiles = [me, marco]

    assert pb.confident_voice(
        _segment(voice_profile_id=marco.id, voice_match="auto"), profiles
    ) is marco
    # "Marco?" is only a suggestion; the user's own voice is never briefed
    assert pb.confident_voice(
        _segment(voice_profile_id=marco.id, voice_match="suggested"), profiles
    ) is None
    assert pb.confident_voice(
        _segment(voice_profile_id=me.id, voice_match="auto"), profiles
    ) is None
    assert pb.confident_voice(_segment(), profiles) is None


async def test_a_known_voice_with_something_to_say_is_briefed(db_session: AsyncSession):
    marco = await _marco(db_session)
    redis = InMemoryRedis()

    command = await pb.brief_who_is_talking(
        db_session, redis, _segment(), _profile(marco), now=NOW
    )

    assert command is not None
    [sent] = _commands(redis)
    assert sent["type"] == "person_brief" and sent["person_id"] == str(marco.id)
    assert sent["title"] == "Talking with Marco Rossi"
    assert sent["body"].startswith("You promised: Send the quote · last talked Oct 13")
    assert sent["body"].endswith(": Atlas launch")
    # Dropped when the phone does not take it within 2 minutes
    expires_at = datetime.fromisoformat(sent["expires_at"])
    assert expires_at <= datetime.now(timezone.utc) + timedelta(seconds=pb.COMMAND_TTL_S)
    assert pb.COMMAND_TTL_S == 120
    assert await ledger.count_on(redis, TEST_USER_ID, TODAY) == 1


async def test_nothing_to_say_no_brief(db_session: AsyncSession):
    luca = Entity(user_id=TEST_USER_ID, entity_type="person", name="Luca")
    db_session.add(luca)
    await db_session.commit()
    redis = InMemoryRedis()

    assert await pb.brief_who_is_talking(
        db_session, redis, _segment(), _profile(luca, name="Luca"), now=NOW
    ) is None
    assert _commands(redis) == []


async def test_once_per_person_every_four_hours(db_session: AsyncSession):
    marco = await _marco(db_session)
    redis = InMemoryRedis()
    voice = _profile(marco)

    assert await pb.brief_who_is_talking(db_session, redis, _segment(), voice, now=NOW)
    later = NOW + timedelta(seconds=30)
    assert await pb.brief_who_is_talking(
        db_session, redis, _segment(recorded_at=later), voice, now=later
    ) is None
    assert len(_commands(redis)) == 1
    key = pb.COOLDOWN_KEY.format(user_id=TEST_USER_ID, person_id=marco.id)
    assert redis.ttls[key] == 4 * 3600


async def test_late_speech_is_not_briefed(db_session: AsyncSession):
    marco = await _marco(db_session)
    redis = InMemoryRedis()

    # Synced from the wearable's backlog an hour later: no longer in front of you
    old = _segment(recorded_at=NOW - timedelta(hours=1))
    assert await pb.brief_who_is_talking(db_session, redis, old, _profile(marco), now=NOW) is None
    assert _commands(redis) == []


async def test_quiet_hours_switch_off_and_three_a_day(db_session: AsyncSession):
    marco = await _marco(db_session)
    voice = _profile(marco)

    night = datetime(2026, 10, 15, 23, tzinfo=user_zone())
    redis = InMemoryRedis()
    assert await pb.brief_who_is_talking(
        db_session, redis, _segment(recorded_at=night), voice, now=night
    ) is None

    redis = InMemoryRedis()
    await ledger.set_briefings(redis, TEST_USER_ID, False)
    assert await pb.brief_who_is_talking(db_session, redis, _segment(), voice, now=NOW) is None

    redis = InMemoryRedis()
    for i in range(3):
        await ledger.record_sent(redis, TEST_USER_ID, f"n{i}", "promises", "tasks", NOW)
    assert await pb.brief_who_is_talking(db_session, redis, _segment(), voice, now=NOW) is None
    assert _commands(redis) == []


async def test_not_within_an_hour_of_a_meeting_briefing(db_session: AsyncSession):
    marco = await _marco(db_session)
    redis = InMemoryRedis()
    briefing = Notice(
        "briefing:m", "briefing", NOW - timedelta(minutes=40), "In 10 min: Call", "b",
        f"person:{marco.id}",
    )
    await ledger.record_scheduled(
        redis, TEST_USER_ID, [briefing], NOW - timedelta(hours=2), NOW + timedelta(hours=30)
    )

    assert await pb.brief_who_is_talking(
        db_session, redis, _segment(), _profile(marco), now=NOW
    ) is None


async def test_a_voice_without_person_link_finds_the_person_by_name(db_session: AsyncSession):
    await _marco(db_session)
    redis = InMemoryRedis()

    command = await pb.brief_who_is_talking(
        db_session, redis, _segment(), _profile(None, name="marco rossi"), now=NOW
    )

    assert command is not None and command["title"] == "Talking with Marco Rossi"
    # A name no person has: nothing to brief
    assert await pb.brief_who_is_talking(
        db_session, InMemoryRedis(), _segment(), _profile(None, name="Zeno"), now=NOW
    ) is None


# --- The STT worker ----------------------------------------------------------------------


class _LoopRedis:
    def __init__(self, items, shutdown):
        self.items = list(items)
        self.pushes = []
        self.shutdown = shutdown

    async def brpop(self, keys, timeout=0):
        if self.items:
            return self.items.pop(0)
        self.shutdown.set()
        return None

    async def lpush(self, queue, payload):
        self.pushes.append((queue, payload))


async def _run_stt(monkeypatch, *, queue=b"queue:stt", voice=(1.0, 0.0), brief=None):
    """One segment through the STT worker, its voice matching Marco's profile (or not)."""
    segment = SimpleNamespace(
        id=uuid.uuid4(), user_id=TEST_USER_ID, audio_energy=10, speaker=None,
        transcription_status="processing", voice_embedding=None, voice_profile_id=None,
        voice_match=None, voice_similarity=None,
    )
    marco = _profile()
    marco.embedding = [1.0, 0.0]
    briefed = []

    class _Db:
        def add(self, obj):
            pass

        async def commit(self):
            pass

    class _Factory:
        async def __aenter__(self):
            return _Db()

        async def __aexit__(self, *exc):
            return False

    async def claim(_db, _redis, _segment_id, **_):
        return segment, b""

    async def context(_db, _user_id):
        return STTContext(prompt="", keyterms=[])

    async def retry(func, *args, **kwargs):
        return SimpleNamespace(text="Ciao, come va il preventivo?", language="it", confidence=0.9)

    async def language(_db, _user_id):
        return "it"

    async def classify(_db, _user_id, _energy):
        return "other"

    async def embed(_wav):
        return list(voice)

    async def profiles(_db, _user_id):
        return [marco]

    async def record(_db, _redis, seg, profile):
        briefed.append((seg.id, profile.id))
        if brief is not None:
            await brief()

    monkeypatch.setattr(
        stt_worker, "get_stt_service",
        lambda: SimpleNamespace(transcribe=None, provider="openai", model="m"),
    )
    monkeypatch.setattr(stt_worker, "async_session", lambda: _Factory())
    monkeypatch.setattr(stt_worker, "_claim_stt_audio", claim)
    monkeypatch.setattr(stt_worker, "adpcm_to_wav", lambda data: data)
    monkeypatch.setattr(stt_worker, "build_stt_context", context)
    monkeypatch.setattr(stt_worker, "retry_with_backoff", retry)
    monkeypatch.setattr(stt_worker, "account_language", language)
    monkeypatch.setattr(stt_worker, "classify_segment", classify)
    monkeypatch.setattr(stt_worker, "embed_voice", embed)
    monkeypatch.setattr(stt_worker, "list_profiles", profiles)
    monkeypatch.setattr(stt_worker, "brief_who_is_talking", record)

    shutdown = asyncio.Event()
    redis = _LoopRedis([(queue, str(segment.id).encode())], shutdown)
    await asyncio.wait_for(stt_worker.process_stt(redis, shutdown), timeout=2)
    return segment, marco, briefed, redis


async def test_the_worker_briefs_a_known_voice(monkeypatch):
    segment, marco, briefed, _ = await _run_stt(monkeypatch)
    assert briefed == [(segment.id, marco.id)]

    # A voice that is nobody known: no brief
    _, _, briefed, _ = await _run_stt(monkeypatch, voice=(0.0, 1.0))
    assert briefed == []


async def test_deferred_speech_is_not_briefed(monkeypatch):
    _, _, briefed, _ = await _run_stt(monkeypatch, queue=b"queue:stt:deferred")
    assert briefed == []


async def test_a_failing_brief_does_not_fail_the_transcription(monkeypatch):
    async def down():
        raise ConnectionError("redis down")

    segment, _, briefed, redis = await _run_stt(monkeypatch, brief=down)

    assert briefed and segment.transcription_status == "completed"
    assert ("queue:analysis", str(segment.id)) in redis.pushes
