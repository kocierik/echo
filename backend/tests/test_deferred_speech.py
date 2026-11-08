"""Past the plan's budget the STT worker defers speech instead of transcribing it: the
audio stays, today's allowance still goes through, and late speech waits for the budget."""

import asyncio
import uuid
from datetime import date, datetime, timezone
from types import SimpleNamespace

from app.models.llm_usage import LlmUsage
from app.models.segment import Segment
from app.services import plans
from app.services.transcription_enhancer import STTContext
from app.workers import stt as stt_worker
from tests.conftest import TEST_USER_ID, test_session

TODAY = date(2026, 10, 24)


class _Redis:
    def __init__(self, items=()):
        self.items = list(items)
        self.pushes = []
        self.popped_from = []

    async def brpop(self, keys, timeout=0):
        self.popped_from.append(keys)
        if self.items:
            return self.items.pop(0)
        self.shutdown.set()
        return None

    async def lpush(self, queue, payload):
        self.pushes.append((queue, payload))


async def _speech(db, day: date, minutes: int):
    db.add(LlmUsage(
        id=uuid.uuid4(), user_id=TEST_USER_ID, day=day, kind="stt",
        model=f"m-{uuid.uuid4().hex[:6]}", calls=1, input_units=minutes * 60,
    ))
    await db.commit()


async def _segment(db, tmp_path, status="pending") -> Segment:
    audio = tmp_path / f"{uuid.uuid4()}.adpcm"
    audio.write_bytes(b"audio")
    now = datetime(2026, 10, 24, 9, tzinfo=timezone.utc)
    segment = Segment(
        id=uuid.uuid4(), user_id=TEST_USER_ID, received_at=now, recorded_at=now,
        duration_ms=8000, audio_path=str(audio), transcription_status=status,
    )
    db.add(segment)
    await db.commit()
    return segment


async def _claim(segment_id, late=False):
    redis = _Redis()
    async with test_session() as db:
        claimed = await stt_worker._claim_stt_audio(db, redis, segment_id, late=late)
    async with test_session() as db:
        status = (await db.get(Segment, segment_id)).transcription_status
    return claimed, status, redis


async def test_past_the_budget_a_segment_is_deferred(db_session, tmp_path, monkeypatch):
    monkeypatch.setattr(plans, "_today", lambda: TODAY)
    await _speech(db_session, date(2026, 10, 2), 300)
    await _speech(db_session, TODAY, 10)  # today's allowance is used too
    segment = await _segment(db_session, tmp_path)

    claimed, status, redis = await _claim(segment.id)

    assert claimed is None
    assert status == "deferred"
    assert redis.pushes == []  # not a failure: nothing in the dead letters
    assert open(segment.audio_path, "rb").read() == b"audio"


async def test_within_the_allowance_it_is_transcribed(db_session, tmp_path, monkeypatch):
    monkeypatch.setattr(plans, "_today", lambda: TODAY)
    await _speech(db_session, date(2026, 10, 2), 300)
    await _speech(db_session, TODAY, 9)
    segment = await _segment(db_session, tmp_path)

    claimed, status, _ = await _claim(segment.id)

    assert claimed is not None and claimed[1] == b"audio"
    assert status == "processing"


async def test_a_late_segment_skips_the_daily_allowance(db_session, tmp_path, monkeypatch):
    monkeypatch.setattr(plans, "_today", lambda: TODAY)
    await _speech(db_session, date(2026, 10, 2), 300)
    segment = await _segment(db_session, tmp_path, status="deferred")

    claimed, status, _ = await _claim(segment.id, late=True)

    assert claimed is None
    assert status == "deferred"


async def test_late_speech_within_the_budget_is_transcribed(db_session, tmp_path, monkeypatch):
    monkeypatch.setattr(plans, "_today", lambda: TODAY)
    await _speech(db_session, date(2026, 10, 2), 200)
    segment = await _segment(db_session, tmp_path, status="deferred")

    claimed, status, _ = await _claim(segment.id, late=True)

    assert claimed is not None
    assert status == "processing"


async def test_a_late_claim_of_a_done_segment_is_skipped(db_session, tmp_path):
    # Queued twice (the hourly release and make set-plan): transcribed once
    segment = await _segment(db_session, tmp_path, status="completed")

    claimed, status, _ = await _claim(segment.id, late=True)

    assert claimed is None
    assert status == "completed"


async def _run(monkeypatch, queue: bytes, text: str):
    segment = SimpleNamespace(
        id=uuid.uuid4(), user_id=TEST_USER_ID, audio_energy=10, speaker=None,
        transcription_status="processing",
    )
    claims = []

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

    async def claim(_db, _redis, segment_id, late=False):
        claims.append((segment_id, late))
        return segment, b""

    async def context(_db, _user_id):
        return STTContext(prompt="", keyterms=[])

    async def retry(func, *args, **kwargs):
        return SimpleNamespace(text=text, language="it", confidence=0.9)

    async def classify(_db, _user_id, _energy):
        return "self"

    async def language(_db, _user_id):
        return ("it", [])

    monkeypatch.setattr(
        stt_worker, "get_stt_service",
        lambda: SimpleNamespace(transcribe=None, provider="openai", model="m"),
    )
    monkeypatch.setattr(stt_worker, "async_session", lambda: _Factory())
    monkeypatch.setattr(stt_worker, "_claim_stt_audio", claim)
    monkeypatch.setattr(stt_worker, "segment_to_wav", lambda data: data)
    monkeypatch.setattr(stt_worker, "build_stt_context", context)
    monkeypatch.setattr(stt_worker, "retry_with_backoff", retry)
    monkeypatch.setattr(stt_worker, "classify_segment", classify)
    monkeypatch.setattr(stt_worker, "account_languages", language)

    shutdown = asyncio.Event()
    redis = _Redis([(queue, str(segment.id).encode())])
    redis.shutdown = shutdown
    await asyncio.wait_for(stt_worker.process_stt(redis, shutdown), timeout=2)
    return segment.id, claims, redis


async def test_late_speech_starts_no_voice_request(monkeypatch):
    segment_id, claims, redis = await _run(
        monkeypatch, b"queue:stt:deferred", "Echo, segnami il dentista"
    )

    assert claims == [(segment_id, True)]
    # Into memory, but a request said weeks ago is not done now
    assert redis.pushes == [("queue:analysis", str(segment_id))]


async def test_live_speech_comes_first(monkeypatch):
    segment_id, claims, redis = await _run(monkeypatch, b"queue:stt", "Echo, segnami il dentista")

    assert claims == [(segment_id, False)]
    assert ("queue:voice", str(segment_id)) in redis.pushes
    assert redis.popped_from[0] == ["queue:stt", "queue:stt:deferred"]
