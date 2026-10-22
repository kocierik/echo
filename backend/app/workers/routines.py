"""Routines: every minute, run the ones that are due (services/routines.py).

A due routine is claimed and moved to its next run in one short transaction (FOR UPDATE
SKIP LOCKED), so two workers never run it twice and a long run holds no lock. It then
runs through the action agent as its user: memory, the connected apps' tools that need no
confirmation, web search; no routine tools. The answer goes to the user's thread with
Echo, and the phone is told to check it (a "voice_update" device command), which shows
the notification. A run missed by more than two hours (the server was down) is skipped.
"""

import asyncio
import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.actions.agent import NO_APPS, run_action_agent
from app.actions.composio_provider import get_action_provider
from app.actions.provider import ActionProviderError
from app.actions.voice import get_or_create_voice_session
from app.core.database import async_session
from app.models.routine import Routine
from app.services.device_commands import push_device_command
from app.services.language import detect_language
from app.services.llm_openai import get_llm_query_service
from app.services.routines import describe_schedule, next_run
from app.services.usage import owned_by
from app.workers.lifecycle import sleep_or_shutdown

logger = logging.getLogger(__name__)

LOOP_INTERVAL_S = 60
# A run missed by more than this is skipped, not run late
CATCH_UP = timedelta(hours=2)
RUN_TIMEOUT_S = 60
BATCH = 20
# The phone checks for the answer while this nudge is valid
NUDGE_TTL_S = 15 * 60

FAILED = {
    "en": "This routine could not run. It will try again at its next time.",
    "it": "Non sono riuscito a eseguire questo incarico. Riproverò alla prossima ora.",
}


@dataclass
class _Due:
    id: uuid.UUID
    user_id: uuid.UUID
    instruction: str
    # "Every day at 07:00", shown with the answer in the thread
    schedule_text: str


async def _claim(session_factory, now: datetime) -> list[_Due]:
    """The due routines to run now; each is moved to its next run (or marked skipped)."""
    due: list[_Due] = []
    async with session_factory() as db:
        routines = await db.scalars(
            select(Routine)
            .where(Routine.active.is_(True), Routine.next_run_at <= now)
            .order_by(Routine.next_run_at)
            .limit(BATCH)
            .with_for_update(skip_locked=True)
        )
        for routine in routines:
            late = now - routine.next_run_at > CATCH_UP
            routine.next_run_at = next_run(routine.schedule, routine.timezone, now)
            if late:
                routine.last_status = "skipped"
                logger.info(f"[Routines] {routine.id} skipped: missed by more than {CATCH_UP}")
                continue
            due.append(_Due(
                routine.id, routine.user_id, routine.instruction,
                describe_schedule(routine.schedule),
            ))
        await db.commit()
    return due


def _provider():
    try:
        return get_action_provider()
    except ActionProviderError:
        return NO_APPS


async def _run_one(session_factory, redis_client, llm, provider, routine: _Due) -> None:
    status, answer = "ok", ""
    with owned_by(routine.user_id):
        async with session_factory() as db:
            asked_at = datetime.now(timezone.utc).isoformat()
            try:
                outcome = await asyncio.wait_for(
                    run_action_agent(
                        db, routine.user_id, routine.instruction, [],
                        session_id=None, source="routine", provider=provider, llm=llm,
                        routine_tools=False, allow_confirm=False,
                    ),
                    RUN_TIMEOUT_S,
                )
                answer, extra = outcome.answer, (
                    {"citations": outcome.web_sources} if outcome.web_sources else {}
                )
            except Exception:
                logger.warning(f"[Routines] {routine.id} failed", exc_info=True)
                await db.rollback()
                status = "failed"
                answer, extra = FAILED[detect_language(routine.instruction)], {}
            thread = await get_or_create_voice_session(db, routine.user_id)
            answered_at = datetime.now(timezone.utc)
            tag = {"routine_id": str(routine.id), "routine_schedule": routine.schedule_text}
            # Reassign (not mutate) so SQLAlchemy sees the JSONB change
            thread.messages = [
                *(thread.messages or []),
                {"role": "user", "content": routine.instruction, "timestamp": asked_at, **tag},
                {
                    "role": "assistant", "content": answer,
                    "timestamp": answered_at.isoformat(), **tag, **extra,
                },
            ]
            thread.updated_at = answered_at
            row = await db.get(Routine, routine.id)
            if row is not None:
                row.last_run_at = answered_at
                row.last_status = status
                row.last_answer = answer
            await db.commit()
    if redis_client is not None:
        try:
            await push_device_command(
                redis_client, routine.user_id, {"type": "voice_update"}, NUDGE_TTL_S
            )
        except Exception:
            logger.warning("[Routines] Could not nudge the phone", exc_info=True)


async def run_due_routines(
    now: datetime,
    *,
    session_factory=None,
    redis_client=None,
    llm=None,
    provider=None,
) -> int:
    """Run the routines due at `now`; returns how many ran (skipped ones not counted)."""
    session_factory = session_factory or async_session
    due = await _claim(session_factory, now)
    if not due:
        return 0
    llm = llm or get_llm_query_service()
    provider = provider or _provider()
    for routine in due:
        await _run_one(session_factory, redis_client, llm, provider, routine)
    return len(due)


async def run_routines_loop(redis_client, shutdown_event: asyncio.Event | None = None):
    logger.info("[Routines] Loop started")
    while not (shutdown_event and shutdown_event.is_set()):
        try:
            ran = await run_due_routines(datetime.now(timezone.utc), redis_client=redis_client)
            if ran:
                logger.info(f"[Routines] Ran {ran}")
        except Exception:
            logger.exception("[Routines] Loop iteration failed")
        if await sleep_or_shutdown(LOOP_INTERVAL_S, shutdown_event):
            return
