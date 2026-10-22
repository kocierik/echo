"""The dead letter queue: what failed after every retry, for Profile → Diagnostics.

`GET /admin/dead-letter` lists it and can push items back to their queue.
"""

import json
import logging
import uuid
from datetime import datetime, timezone

import redis.asyncio as redis

logger = logging.getLogger(__name__)

DEAD_LETTER_QUEUE = "queue:dead-letter"


async def push_to_dead_letter(
    redis_client: redis.Redis,
    segment_id: uuid.UUID,
    step: str,
    error: str,
    attempts: int = 3,
):
    """Push a failed segment to the dead letter queue."""
    entry = {
        "segment_id": str(segment_id),
        "step": step,
        "error": str(error)[:500],
        "attempts": attempts,
        "failed_at": datetime.now(timezone.utc).isoformat(),
    }
    await redis_client.lpush(DEAD_LETTER_QUEUE, json.dumps(entry))
    logger.warning(f"[DeadLetter] Segment {segment_id} pushed to dead letter (step={step})")


async def push_reanalysis_to_dead_letter(
    redis_client: redis.Redis,
    raw_payload: str,
    error: str,
    *,
    attempts: int = 0,
    conversation_id: uuid.UUID | None = None,
):
    entry = {
        "conversation_id": str(conversation_id) if conversation_id else None,
        "step": "reanalysis",
        "error": str(error)[:500],
        "attempts": attempts,
        "payload": raw_payload[:1000],
        "failed_at": datetime.now(timezone.utc).isoformat(),
    }
    await redis_client.lpush(DEAD_LETTER_QUEUE, json.dumps(entry))
    logger.warning(
        "[DeadLetter] Reanalysis payload pushed to dead letter "
        f"(conversation_id={conversation_id})"
    )
