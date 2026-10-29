"""The operator's endpoints (ADMIN_TOKEN): the dead letter queue, every user's failed jobs."""

import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel

from app.core.auth import require_operator

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_operator)])

DEAD_LETTER_QUEUE = "queue:dead-letter"


class DeadLetterItem(BaseModel):
    # Segment entries (stt/analysis) carry segment_id; reanalysis entries carry
    # conversation_id (None when the original payload was malformed).
    segment_id: str | None = None
    conversation_id: str | None = None
    step: str
    error: str
    attempts: int = 0
    failed_at: str


class DeadLetterResponse(BaseModel):
    items: list[DeadLetterItem]
    count: int


class RetryResponse(BaseModel):
    requeued: int
    kept: int


def _retry_target(raw: bytes | str) -> tuple[str, str] | None:
    """Return (queue, payload) to requeue a dead letter entry, or None if not retryable."""
    try:
        data = json.loads(raw)
    except (TypeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None

    step = data.get("step")
    segment_id = data.get("segment_id")
    conversation_id = data.get("conversation_id")

    if step in ("stt", "analysis") and segment_id:
        return f"queue:{step}", segment_id
    if step == "reanalysis" and conversation_id:
        payload = {
            "conversation_id": conversation_id,
            "requested_at": datetime.now(timezone.utc).isoformat(),
            "attempts": 0,
        }
        return "queue:reanalysis", json.dumps(payload)
    return None


@router.get("/dead-letter", response_model=DeadLetterResponse)
async def list_dead_letter(request: Request):
    """List all items in the dead letter queue."""
    redis_client = request.app.state.redis
    raw_items = await redis_client.lrange(DEAD_LETTER_QUEUE, 0, -1)
    items = []
    for raw in raw_items:
        try:
            items.append(DeadLetterItem.model_validate_json(raw))
        except ValueError:
            continue  # Unreadable entry: leave it in Redis, skip it in the listing
    return DeadLetterResponse(items=items, count=len(items))


@router.post("/dead-letter/retry", response_model=RetryResponse)
async def retry_dead_letter(request: Request):
    """Re-queue dead letter items to their processing queue.

    Entries that cannot be retried (malformed or missing their target ID) are
    put back in the dead letter queue instead of being dropped.
    """
    redis_client = request.app.state.redis
    requeued = 0
    kept: list[bytes | str] = []

    # Bound the loop to the current length so entries pushed meanwhile are left alone
    pending = await redis_client.llen(DEAD_LETTER_QUEUE)
    for _ in range(pending):
        raw = await redis_client.rpop(DEAD_LETTER_QUEUE)
        if raw is None:
            break
        target = _retry_target(raw)
        if target is None:
            kept.append(raw)
            continue
        queue, payload = target
        await redis_client.lpush(queue, payload)
        requeued += 1

    # Restore kept entries at the oldest end, preserving their original order
    for raw in reversed(kept):
        await redis_client.rpush(DEAD_LETTER_QUEUE, raw)

    return RetryResponse(requeued=requeued, kept=len(kept))
