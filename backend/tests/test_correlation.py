"""One correlation ID from an upload to the workers that handle it (core/logging.py).

The queues keep carrying bare ids; the uploading request keeps its correlation ID in
Redis beside the object (corr:segment:{id}, corr:photo:{id}) and the workers restore it.
"""

import asyncio
import logging
import uuid

import pytest

from app.core import logging as core_logging
from app.core.config import settings
from app.core.logging import (
    correlation_id,
    new_correlation_id,
    remember_correlation,
    restore_correlation_for,
)
from app.main import app
from app.workers import photos as photo_worker
from app.workers import stt as stt_worker
from tests.fakes.redis import InMemoryRedis

AUDIO = b"\x00\x11\x22\x33" * 250


@pytest.fixture
def tracking(monkeypatch):
    monkeypatch.setattr(settings, "run_tracking_enabled", True)


class _OrderedRedis(InMemoryRedis):
    """Remembers the order of writes, to see the key is set before the id is queued."""

    def __init__(self):
        super().__init__()
        self.calls: list[tuple[str, str]] = []

    async def set(self, key, value, nx=False, ex=None):
        self.calls.append(("set", key))
        return await super().set(key, value, nx=nx, ex=ex)

    async def lpush(self, key, *values):
        self.calls.append(("lpush", key))
        return await super().lpush(key, *values)


class _BrokenRedis(_OrderedRedis):
    async def set(self, key, value, nx=False, ex=None):
        raise ConnectionError("redis down")

    async def get(self, key):
        raise ConnectionError("redis down")


async def _upload(client, auth_headers, redis) -> tuple[str, str]:
    app.state.redis = redis  # the client fixture puts its own back afterwards
    response = await client.post(
        "/api/segments",
        headers={**auth_headers, "X-Recorded-At": "2026-10-30T10:30:00Z", "X-Duration-Ms": "5000"},
        files={"audio": ("segment.adpcm", AUDIO + uuid.uuid4().bytes, "application/octet-stream")},
    )
    assert response.status_code == 201
    return response.json()["id"], response.headers["X-Correlation-ID"]


async def test_an_upload_keeps_its_correlation_id_before_queueing(
    tracking, client, auth_headers
):
    redis = _OrderedRedis()

    segment_id, cid = await _upload(client, auth_headers, redis)

    key = f"corr:segment:{segment_id}"
    assert redis.calls == [("set", key), ("lpush", "queue:stt")]
    assert await redis.get(key) == cid.encode()
    assert redis.ttls[key] == 7 * 24 * 3600


async def test_with_tracking_off_no_key_is_written(client, auth_headers):
    redis = _OrderedRedis()

    await _upload(client, auth_headers, redis)

    assert redis.calls == [("lpush", "queue:stt")]
    assert not [k for k in redis.values if k.startswith("corr:")]


async def test_redis_failing_never_fails_the_upload(tracking, client, auth_headers, caplog):
    redis = _BrokenRedis()

    with caplog.at_level(logging.WARNING, logger="app.core.logging"):
        await _upload(client, auth_headers, redis)

    assert redis.calls == [("lpush", "queue:stt")]
    [warning] = [r for r in caplog.records if "correlation" in r.getMessage()]
    assert warning.error_class == "ConnectionError"


async def test_the_stt_worker_logs_under_the_upload_correlation_id(tracking):
    redis = InMemoryRedis()
    segment_id = uuid.uuid4()  # not in the database: the worker logs it and moves on
    correlation_id.set("upload-1")
    await remember_correlation(redis, "segment", segment_id)
    new_correlation_id()  # the worker's own context
    shutdown = asyncio.Event()

    async def brpop(keys, timeout=0):
        shutdown.set()
        return b"queue:stt", str(segment_id).encode()

    redis.brpop = brpop
    await stt_worker.process_stt(redis, shutdown)

    assert correlation_id.get() == "upload-1"


async def test_a_missing_or_expired_key_gives_a_new_id(tracking):
    redis = InMemoryRedis()
    correlation_id.set("before")

    restored = await restore_correlation_for(redis, "segment", uuid.uuid4())

    assert restored != "before" and len(restored) == 8
    assert correlation_id.get() == restored


async def test_redis_failing_on_read_gives_a_new_id(tracking, caplog):
    correlation_id.set("before")

    with caplog.at_level(logging.WARNING, logger="app.core.logging"):
        restored = await restore_correlation_for(_BrokenRedis(), "photo", uuid.uuid4())

    assert restored not in ("", "before")
    assert any(r.error_class == "ConnectionError" for r in caplog.records)


async def test_with_tracking_off_the_worker_does_not_read_redis():
    class _NoReads(InMemoryRedis):
        async def get(self, key):
            raise AssertionError("read with tracking off")

    restored = await restore_correlation_for(_NoReads(), "segment", uuid.uuid4())

    assert restored and correlation_id.get() == restored


async def test_a_replay_from_the_dead_letter_queue_keeps_the_id(tracking):
    redis = InMemoryRedis()
    segment_id = uuid.uuid4()
    correlation_id.set("upload-2")
    await remember_correlation(redis, "segment", segment_id)

    first = await restore_correlation_for(redis, "segment", segment_id)
    new_correlation_id()  # other jobs in between; then the operator replays the id
    again = await restore_correlation_for(redis, "segment", segment_id)

    assert first == again == "upload-2"


async def test_the_photo_worker_restores_the_upload_correlation_id(tracking, monkeypatch):
    redis = InMemoryRedis()
    photo_id = uuid.uuid4()
    correlation_id.set("photo-up")
    await remember_correlation(redis, "photo", photo_id)
    new_correlation_id()
    seen = []

    async def analyse(found_id, _session_factory, _redis=None):
        seen.append((found_id, core_logging.correlation_id.get()))

    monkeypatch.setattr(photo_worker, "_analyse_once", analyse)
    await photo_worker.handle_photo(str(photo_id).encode(), None, redis)

    assert seen == [(photo_id, "photo-up")]


async def test_a_photo_upload_keeps_its_correlation_id_before_queueing(
    tracking, client, auth_headers
):
    redis = _OrderedRedis()
    app.state.redis = redis
    photo = (await client.post("/api/photos", headers=auth_headers, json={})).json()

    response = await client.put(
        f"/api/photos/{photo['id']}/image",
        headers={**auth_headers, "X-Captured-At": "2026-10-30T10:30:00+00:00"},
        files={"image": ("photo.jpg", b"\xff\xd8\xff\xe0" + b"\x00" * 64, "image/jpeg")},
    )

    assert response.status_code == 201
    key = f"corr:photo:{photo['id']}"
    assert [c for c in redis.calls if c[1] in (key, "queue:photos")] == [
        ("set", key), ("lpush", "queue:photos"),
    ]
    assert await redis.get(key) == response.headers["X-Correlation-ID"].encode()
