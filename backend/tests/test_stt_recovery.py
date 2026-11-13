import uuid
from datetime import datetime, timedelta, timezone

from app.models.segment import Segment
from app.workers import stt as stt_worker
from tests.conftest import TEST_USER_ID, test_session
from tests.fakes.redis import InMemoryRedis


async def test_recovery_requeues_pending_and_stale_processing_segments(
    db_session, tmp_path
):
    now = datetime.now(timezone.utc)
    stale = Segment(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        received_at=now - timedelta(minutes=2),
        recorded_at=now - timedelta(minutes=2),
        duration_ms=1000,
        audio_path=str(tmp_path / "stale.adpcm"),
        transcription_status="processing",
        transcription_started_at=now - stt_worker.STT_PROCESSING_TIMEOUT - timedelta(seconds=1),
    )
    pending = Segment(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        received_at=now,
        recorded_at=now,
        duration_ms=1000,
        audio_path=str(tmp_path / "pending.adpcm"),
        transcription_status="pending",
    )
    active = Segment(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        received_at=now,
        recorded_at=now + timedelta(seconds=1),
        duration_ms=1000,
        audio_path=str(tmp_path / "active.adpcm"),
        transcription_status="processing",
        transcription_started_at=now,
    )
    db_session.add_all([stale, pending, active])
    await db_session.commit()
    redis = InMemoryRedis()

    recovered = await stt_worker.recover_stt_queue(
        redis, session_factory=test_session, now=now
    )

    assert recovered == 2
    assert redis.lists[stt_worker.STT_QUEUE] == [str(pending.id), str(stale.id)]
    async with test_session() as db:
        assert (await db.get(Segment, stale.id)).transcription_status == "pending"
        assert (await db.get(Segment, active.id)).transcription_status == "processing"


async def test_recovery_waits_until_existing_queue_is_empty(db_session, tmp_path):
    now = datetime.now(timezone.utc)
    segment = Segment(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        received_at=now,
        recorded_at=now,
        duration_ms=1000,
        audio_path=str(tmp_path / "pending.adpcm"),
        transcription_status="pending",
    )
    db_session.add(segment)
    await db_session.commit()
    redis = InMemoryRedis()
    await redis.lpush(stt_worker.STT_QUEUE, "already-queued")

    recovered = await stt_worker.recover_stt_queue(redis, session_factory=test_session, now=now)

    assert recovered == 0
    assert redis.lists[stt_worker.STT_QUEUE] == ["already-queued"]


async def test_recovery_waits_while_live_speech_is_queued(db_session, tmp_path):
    now = datetime.now(timezone.utc)
    segment = Segment(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        received_at=now,
        recorded_at=now,
        duration_ms=1000,
        audio_path=str(tmp_path / "pending.adpcm"),
        transcription_status="pending",
    )
    db_session.add(segment)
    await db_session.commit()
    redis = InMemoryRedis()
    await redis.lpush(stt_worker.LIVE_STT_QUEUE, str(segment.id))

    recovered = await stt_worker.recover_stt_queue(redis, session_factory=test_session, now=now)

    assert recovered == 0
    assert stt_worker.STT_QUEUE not in redis.lists
