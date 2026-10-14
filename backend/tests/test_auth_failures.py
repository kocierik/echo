"""Failed API key attempts are limited per client before the key is checked."""

import types
import uuid

import pytest
from fastapi import HTTPException

from app.core import auth
from tests.fakes.redis import InMemoryRedis as FakeRedis


class BrokenRedis:
    async def get(self, key):
        raise ConnectionError("redis down")

    incr = expire = ttl = get


class FakeDB:
    """Answers the ApiKey lookup: a record only for the hash of `valid_key`."""

    def __init__(self, valid_key="good-key"):
        self.valid_hash = auth.hash_api_key(valid_key)
        self.user_id = uuid.uuid4()
        self.lookups = 0

    async def execute(self, stmt):
        self.lookups += 1
        wanted = stmt.compile().params.get("key_hash_1")
        record = (
            types.SimpleNamespace(user_id=self.user_id, last_used_at=None)
            if wanted == self.valid_hash
            else None
        )
        return types.SimpleNamespace(scalar_one_or_none=lambda: record)


def _request(redis, host="10.0.0.1", headers=None):
    app = types.SimpleNamespace(state=types.SimpleNamespace(redis=redis))
    return types.SimpleNamespace(
        app=app,
        client=types.SimpleNamespace(host=host),
        headers=headers or {},
    )


async def _attempt(request, db, key="wrong-key"):
    return await auth.get_current_user_id(request, api_key=key, db=db)


@pytest.mark.asyncio
async def test_a_valid_key_is_accepted():
    db = FakeDB()
    assert await _attempt(_request(FakeRedis()), db, "good-key") == db.user_id


@pytest.mark.asyncio
async def test_after_ten_failures_the_client_gets_429_without_a_key_lookup():
    redis, db = FakeRedis(), FakeDB()
    request = _request(redis)
    for _ in range(auth.AUTH_FAILURE_LIMIT):
        with pytest.raises(HTTPException) as exc:
            await _attempt(request, db)
        assert exc.value.status_code == 401
    lookups = db.lookups

    with pytest.raises(HTTPException) as exc:
        await _attempt(request, db, "good-key")  # even the right key: no oracle
    assert exc.value.status_code == 429
    assert exc.value.headers["Retry-After"] == str(auth.AUTH_FAILURE_WINDOW_SECONDS)
    assert db.lookups == lookups


@pytest.mark.asyncio
async def test_the_failure_window_is_set_on_the_first_failure():
    redis = FakeRedis()
    with pytest.raises(HTTPException):
        await _attempt(_request(redis), FakeDB())
    assert list(redis.ttls.values()) == [auth.AUTH_FAILURE_WINDOW_SECONDS]


@pytest.mark.asyncio
async def test_clients_behind_cloudflare_are_counted_apart():
    redis, db = FakeRedis(), FakeDB()
    attacker = _request(redis, host="172.17.0.1", headers={"CF-Connecting-IP": "203.0.113.9"})
    for _ in range(auth.AUTH_FAILURE_LIMIT):
        with pytest.raises(HTTPException):
            await _attempt(attacker, db)

    owner = _request(redis, host="172.17.0.1", headers={"CF-Connecting-IP": "198.51.100.4"})
    assert await _attempt(owner, db, "good-key") == db.user_id


@pytest.mark.asyncio
async def test_a_redis_outage_does_not_block_authentication():
    db = FakeDB()
    request = _request(BrokenRedis())
    assert await _attempt(request, db, "good-key") == db.user_id
    with pytest.raises(HTTPException) as exc:
        await _attempt(request, db)
    assert exc.value.status_code == 401
