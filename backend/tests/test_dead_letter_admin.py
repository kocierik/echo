"""Unit tests: dead letter listing and retry handle segment and reanalysis entries."""

import json
import uuid
from types import SimpleNamespace

import pytest

from app.routers import admin

USER_ID = uuid.UUID("a0000000-0000-0000-0000-000000000001")


class _FakeRedis:
    """Minimal Redis list semantics (left = newest, right = oldest)."""

    def __init__(self, lists=None):
        self.lists = {key: list(values) for key, values in (lists or {}).items()}

    async def lrange(self, key, start, end):
        values = self.lists.get(key, [])
        return values[start:] if end == -1 else values[start : end + 1]

    async def llen(self, key):
        return len(self.lists.get(key, []))

    async def rpop(self, key):
        values = self.lists.get(key, [])
        return values.pop() if values else None

    async def lpush(self, key, value):
        self.lists.setdefault(key, []).insert(0, value)

    async def rpush(self, key, value):
        self.lists.setdefault(key, []).append(value)


def _request(redis):
    return SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace(redis=redis)))


SEGMENT_ID = str(uuid.uuid4())
CONVERSATION_ID = str(uuid.uuid4())

STT_ENTRY = json.dumps({
    "segment_id": SEGMENT_ID,
    "step": "stt",
    "error": "timeout",
    "attempts": 3,
    "failed_at": "2026-10-13T10:00:00+00:00",
})
REANALYSIS_ENTRY = json.dumps({
    "conversation_id": CONVERSATION_ID,
    "step": "reanalysis",
    "error": "boom",
    "attempts": 2,
    "payload": "{}",
    "failed_at": "2026-10-13T10:01:00+00:00",
})
MALFORMED_REANALYSIS_ENTRY = json.dumps({
    "conversation_id": None,
    "step": "reanalysis",
    "error": "bad payload",
    "attempts": 0,
    "payload": "not json",
    "failed_at": "2026-10-13T10:02:00+00:00",
})


@pytest.mark.asyncio
async def test_list_includes_reanalysis_entries():
    queue = [MALFORMED_REANALYSIS_ENTRY, REANALYSIS_ENTRY, STT_ENTRY, b"garbage"]
    redis = _FakeRedis({admin.DEAD_LETTER_QUEUE: queue})

    response = await admin.list_dead_letter(_request(redis), _user_id=USER_ID)

    assert response.count == 3
    assert {item.step for item in response.items} == {"stt", "reanalysis"}
    reanalysis = next(item for item in response.items if item.conversation_id)
    assert reanalysis.segment_id is None


@pytest.mark.asyncio
async def test_retry_requeues_each_step_and_keeps_unretryable_entries():
    queue = [MALFORMED_REANALYSIS_ENTRY, REANALYSIS_ENTRY, STT_ENTRY, "garbage"]
    redis = _FakeRedis({admin.DEAD_LETTER_QUEUE: queue})

    response = await admin.retry_dead_letter(_request(redis), _user_id=USER_ID)

    assert response.requeued == 2
    assert response.kept == 2
    assert redis.lists["queue:stt"] == [SEGMENT_ID]
    reanalysis_payload = json.loads(redis.lists["queue:reanalysis"][0])
    assert reanalysis_payload["conversation_id"] == CONVERSATION_ID
    assert reanalysis_payload["attempts"] == 0
    assert reanalysis_payload["requested_at"]
    # Unretryable entries stay in the dead letter queue, in their original order
    assert redis.lists[admin.DEAD_LETTER_QUEUE] == [MALFORMED_REANALYSIS_ENTRY, "garbage"]


@pytest.mark.asyncio
async def test_retry_on_empty_queue_does_nothing():
    redis = _FakeRedis()

    response = await admin.retry_dead_letter(_request(redis), _user_id=USER_ID)

    assert response.requeued == 0
    assert response.kept == 0
