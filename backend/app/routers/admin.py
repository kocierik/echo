"""Admin endpoints for monitoring and managing the dead letter queue."""

import json
import uuid

import redis.asyncio as redis
from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.core.auth import get_current_user_id
from app.core.config import settings

router = APIRouter(prefix="/admin", tags=["admin"])


class DeadLetterItem(BaseModel):
    segment_id: str
    step: str
    error: str
    attempts: int
    failed_at: str


class DeadLetterResponse(BaseModel):
    items: list[DeadLetterItem]
    count: int


class RetryResponse(BaseModel):
    requeued: int


@router.get("/dead-letter", response_model=DeadLetterResponse)
async def list_dead_letter(
    _user_id: uuid.UUID = Depends(get_current_user_id),
):
    """List all items in the dead letter queue."""
    redis_client = redis.from_url(settings.redis_url)
    try:
        raw_items = await redis_client.lrange("queue:dead-letter", 0, -1)
        items = []
        for raw in raw_items:
            data = json.loads(raw)
            items.append(DeadLetterItem(**data))
        return DeadLetterResponse(items=items, count=len(items))
    finally:
        await redis_client.aclose()


@router.post("/dead-letter/retry", response_model=RetryResponse)
async def retry_dead_letter(
    _user_id: uuid.UUID = Depends(get_current_user_id),
):
    """Re-queue all dead letter items back to their appropriate processing queue."""
    redis_client = redis.from_url(settings.redis_url)
    try:
        requeued = 0
        while True:
            raw = await redis_client.rpop("queue:dead-letter")
            if raw is None:
                break
            data = json.loads(raw)
            segment_id = data["segment_id"]
            step = data["step"]

            # Push back to the appropriate queue
            if step == "stt":
                await redis_client.lpush("queue:stt", segment_id)
            elif step == "analysis":
                await redis_client.lpush("queue:analysis", segment_id)
            requeued += 1

        return RetryResponse(requeued=requeued)
    finally:
        await redis_client.aclose()
