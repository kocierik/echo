"""Queues a killed worker does not lose.

A loop takes an item with `take` (it moves to `<queue>:working`) and removes it with `done`
once it has dealt with it, however that went: handled, sent to the dead letter queue, or
queued again by the loop itself. A process killed in between (out of memory, power) leaves
the item there, and `restore_working` at the next start puts it back, once. An item found
there a second time was in hand at two kills: it is dropped and logged, so an item that
kills its worker cannot do so for ever.

shortcut: one worker process (docker-compose.yml). With several, restoring at start would
take the items the others have in hand: restore by age then.
"""

import hashlib
import logging

logger = logging.getLogger(__name__)

# How long an item restored once is remembered
RESTORED_TTL_S = 24 * 3600


def _working(queue: str) -> str:
    return f"{queue}:working"


async def take(redis_client, queue: str, timeout: float = 2):
    """The oldest item (producers lpush), waiting up to `timeout` seconds; None if none."""
    return await redis_client.blmove(queue, _working(queue), timeout, "RIGHT", "LEFT")


async def take_now(redis_client, queue: str):
    """The oldest item without waiting; None when the queue is empty."""
    return await redis_client.lmove(queue, _working(queue), "RIGHT", "LEFT")


async def done(redis_client, queue: str, raw) -> None:
    await redis_client.lrem(_working(queue), 1, raw)


async def restore_working(redis_client, queue: str) -> int:
    """Put back what a killed worker had in hand; how many items went back."""
    restored = 0
    while (raw := await redis_client.rpop(_working(queue))) is not None:
        data = raw if isinstance(raw, bytes) else str(raw).encode()
        key = f"{queue}:restored:{hashlib.sha1(data).hexdigest()}"
        if await redis_client.set(key, "1", nx=True, ex=RESTORED_TTL_S):
            await redis_client.rpush(queue, raw)  # the oldest: taken first
            restored += 1
        else:
            logger.error("[Queue] %s: an item in hand at two kills is dropped: %r", queue, raw)
    if restored:
        logger.warning("[Queue] %s: %d item(s) a killed worker left are queued again",
                       queue, restored)
    return restored
