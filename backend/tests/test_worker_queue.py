"""Queues a killed worker does not lose (workers/queue.py), against the real Redis."""

import uuid

import pytest
import redis.asyncio as aioredis

from app.core.config import settings
from app.workers.queue import done, restore_working, take, take_now


@pytest.fixture
async def queue():
    client = aioredis.from_url(settings.redis_url)
    name = f"queue:test:{uuid.uuid4()}"
    yield client, name
    keys = [key async for key in client.scan_iter(f"{name}*")]
    if keys:
        await client.delete(*keys)
    await client.aclose()


async def test_the_oldest_item_is_taken_and_gone_once_done(queue):
    client, name = queue
    await client.lpush(name, "first")
    await client.lpush(name, "second")

    raw = await take(client, name, timeout=1)

    assert raw == b"first"
    assert await client.lrange(f"{name}:working", 0, -1) == [b"first"]
    await done(client, name, raw)
    assert await client.llen(f"{name}:working") == 0
    assert await take_now(client, name) == b"second"
    assert await take_now(client, name) is None
    assert await take(client, name, timeout=0.05) is None


async def test_what_a_killed_worker_had_in_hand_goes_back_once(queue):
    client, name = queue
    await client.lpush(name, "in-hand")
    await client.lpush(name, "waiting")
    await take(client, name, timeout=1)  # the worker is killed here: never done

    assert await restore_working(client, name) == 1

    # Back as the oldest: taken before what was waiting
    assert await take_now(client, name) == b"in-hand"
    # Killed again with the same item in hand: it would kill the worker for ever
    assert await restore_working(client, name) == 0
    assert await client.llen(f"{name}:working") == 0
    assert await client.lrange(name, 0, -1) == [b"waiting"]


async def test_nothing_in_hand_nothing_restored(queue):
    client, name = queue

    assert await restore_working(client, name) == 0
