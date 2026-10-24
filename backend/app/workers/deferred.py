"""Deferred speech goes back to transcription when the plan's budget allows it again.

Every hour, and at once when the operator changes a plan (`make set-plan`), each user's
deferred segments are queued on `queue:stt:deferred`, oldest first, up to what is left of
the month's budget (so at most a month's speech at a time): on the 1st, or as soon as a
plan is raised. The STT worker reads that queue only when no live speech waits, and checks
the budget again for each segment (workers/stt.py). Nothing is queued while the queue
still holds some, so the same segment is not queued twice by two runs.
"""

import asyncio
import logging
import uuid
from datetime import date, datetime, timezone

import redis.asyncio as redis
from sqlalchemy import func, select

from app.core.database import async_session
from app.models.segment import Segment
from app.services.plans import month_start, speech_seconds, user_plan
from app.workers.lifecycle import sleep_or_shutdown
from app.workers.stt import DEFERRED_STT_QUEUE

logger = logging.getLogger(__name__)

RELEASE_INTERVAL_S = 3600
_PUSH_BATCH = 500


async def _waiting_within(db, user_id: uuid.UUID, seconds: int) -> list[uuid.UUID]:
    """The user's deferred segments, oldest first, until `seconds` of speech (the one that
    crosses the line included)."""
    running = func.sum(Segment.duration_ms).over(order_by=(Segment.recorded_at, Segment.id))
    waiting = (
        select(Segment.id, Segment.duration_ms, running.label("running"))
        .where(Segment.user_id == user_id, Segment.transcription_status == "deferred")
        .subquery()
    )
    rows = await db.scalars(
        select(waiting.c.id)
        .where(waiting.c.running - waiting.c.duration_ms < seconds * 1000)
        .order_by(waiting.c.running)
    )
    return list(rows)


async def release_deferred(
    redis_client: redis.Redis,
    *,
    session_factory=async_session,
    user_id: uuid.UUID | None = None,
    today: date | None = None,
) -> int:
    """Queue the deferred speech the budget allows now (one user's, or everyone's).
    Returns how many segments were queued."""
    if await redis_client.llen(DEFERRED_STT_QUEUE):
        return 0
    today = today or datetime.now(timezone.utc).date()
    queued: list[uuid.UUID] = []
    async with session_factory() as db:
        if user_id is not None:
            users = [user_id]
        else:
            users = list(await db.scalars(
                select(Segment.user_id)
                .where(Segment.transcription_status == "deferred")
                .distinct()
            ))
        for owner in users:
            plan = await user_plan(db, owner)
            room = plan.monthly_minutes * 60 - await speech_seconds(db, owner, month_start(today))
            if room > 0:
                queued += await _waiting_within(db, owner, room)
    # Oldest first: lpush adds on the left, the worker pops from the right
    for start in range(0, len(queued), _PUSH_BATCH):
        await redis_client.lpush(
            DEFERRED_STT_QUEUE, *(str(i) for i in queued[start:start + _PUSH_BATCH])
        )
    return len(queued)


async def run_deferred_loop(redis_client: redis.Redis, shutdown_event: asyncio.Event | None = None):
    while not (shutdown_event and shutdown_event.is_set()):
        try:
            released = await release_deferred(redis_client)
            if released:
                logger.info("[Deferred] %s deferred segments queued for transcription", released)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Deferred] Release failed")
        if await sleep_or_shutdown(RELEASE_INTERVAL_S, shutdown_event):
            return
