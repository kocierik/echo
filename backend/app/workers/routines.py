"""Routines: every minute, run the ones that are due (services/routines.py).

A due routine is claimed and moved to its next run in one short transaction (FOR UPDATE
SKIP LOCKED), so two workers never run it twice and a long run holds no lock. It then
runs through the action agent as its user: memory, the connected apps' tools that need no
confirmation, web search; no routine tools.

Each run is recorded as a RoutineRun, never in the user's thread. An `always` routine
reports its answer; `only_if` and `only_new` ask the agent for a JSON result
(services/routine_results.py) and stay quiet ("nothing") when there is nothing to say or,
for `only_new`, nothing this routine has not reported before. An answer that cannot be
read is converted once by the model, else reported as it is: when in doubt, report.
After a run that reports or fails the phone is told to check (a "voice_update" device
command), which shows the notification; a quiet one tells it nothing. A run missed by more
than two hours (the server was down) is recorded as skipped. Runs older than 90 days are
deleted once a day.
"""

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.actions.agent import NO_APPS, TEXTS, run_action_agent
from app.actions.composio_provider import get_action_provider
from app.actions.provider import ActionProviderError
from app.core.database import async_session
from app.models.routine import Routine
from app.services.device_commands import push_device_command
from app.services.language import detect_language
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_query_service
from app.services.routine_results import (
    CONVERT_PROMPT,
    compose_text,
    framed_request,
    fresh_items,
    parse_result,
)
from app.services.routine_runs import delete_old_runs, record_run, seen_items, seen_keys
from app.services.routines import next_run
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
# The runs the phone is told about; quiet and skipped ones are not
NOTIFIED = ("reported", "failed")

FAILED = {
    "en": "This routine could not run. It will try again at its next time.",
    "it": "Non sono riuscito a eseguire questo incarico. Riproverò alla prossima ora.",
}


@dataclass
class _Due:
    id: uuid.UUID
    user_id: uuid.UUID
    instruction: str
    # "always" | "only_if" | "only_new"
    mode: str


@dataclass
class _Result:
    status: str
    text: str | None = None
    sources: list[dict] = field(default_factory=list)
    items: list[dict] = field(default_factory=list)


async def _claim(session_factory, now: datetime) -> list[_Due]:
    """The due routines to run now; each is moved to its next run (or recorded as
    skipped, at the time it was missed)."""
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
            missed_at = routine.next_run_at
            routine.next_run_at = next_run(routine.schedule, routine.timezone, now)
            if now - missed_at > CATCH_UP:
                await record_run(db, routine, status="skipped", ran_at=missed_at)
                logger.info(f"[Routines] {routine.id} skipped: missed by more than {CATCH_UP}")
                continue
            due.append(_Due(routine.id, routine.user_id, routine.instruction, routine.mode))
        await db.commit()
    return due


def _provider():
    try:
        return get_action_provider()
    except ActionProviderError:
        return NO_APPS


def _could_not_answer(answer: str, language: str) -> bool:
    """One of the agent's own texts for an answer it could not give (apps unreachable, too
    many steps, no answer): a failed run, not a quiet one."""
    texts = TEXTS[language]
    return any(answer.startswith(texts[key]) for key in ("unreachable", "step_limit", "no_answer"))


async def _ask(db, llm, provider, routine: _Due) -> _Result:
    """Run the agent on the routine's request and read what it found, by mode."""
    only_new = routine.mode == "only_new"
    seen = await seen_items(db, routine.id) if only_new else []
    known = await seen_keys(db, routine.id) if only_new else set()
    language = detect_language(routine.instruction)
    outcome = await run_action_agent(
        db, routine.user_id, framed_request(routine.instruction, routine.mode, seen), [],
        session_id=None, source="routine", provider=provider, llm=llm,
        routine_tools=False, allow_confirm=False, language=language,
    )
    sources = outcome.web_sources or []
    if _could_not_answer(outcome.answer, language):
        return _Result("failed", outcome.answer)
    if routine.mode == "always":
        return _Result("reported", outcome.answer, sources)
    result = parse_result(outcome.answer, routine.mode)
    if result is None:
        converted = await llm.complete([
            LLMMessage(role="system", content=CONVERT_PROMPT),
            LLMMessage(role="user", content=outcome.answer),
        ])
        result = parse_result(converted.content, routine.mode)
    if result is None:
        logger.info(f"[Routines] {routine.id}: no readable result, reported as it is")
        return _Result("reported", outcome.answer, sources)
    if only_new:
        if result.report and not result.items and (result.text or result.intro):
            # What it found is in the text, not in items: told as it is, never dropped
            return _Result("reported", result.text or result.intro, sources)
        fresh = fresh_items(result.items, known)
        if not fresh:
            return _Result("nothing")
        kept = [{"key": i["key"], "title": i["title"], "url": i["url"]} for i in fresh]
        return _Result("reported", compose_text(result.intro, fresh), sources, kept)
    if not result.report:
        return _Result("nothing")
    return _Result("reported", result.text or result.intro or outcome.answer, sources)


async def _run_one(session_factory, redis_client, llm, provider, routine: _Due) -> None:
    with owned_by(routine.user_id):
        async with session_factory() as db:
            try:
                # The conversion call, when there is one, is inside the same budget
                result = await asyncio.wait_for(_ask(db, llm, provider, routine), RUN_TIMEOUT_S)
            except Exception:
                logger.warning(f"[Routines] {routine.id} failed", exc_info=True)
                await db.rollback()
                result = _Result("failed", FAILED[detect_language(routine.instruction)])
            row = await db.get(Routine, routine.id)
            if row is not None:
                await record_run(
                    db, row, status=result.status, ran_at=datetime.now(timezone.utc),
                    text=result.text, sources=result.sources, items=result.items,
                )
            await db.commit()
    if redis_client is not None and result.status in NOTIFIED:
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
        try:
            await _run_one(session_factory, redis_client, llm, provider, routine)
        except Exception:
            # Its session broke (a cancelled call, a failed rollback): recorded as failed
            # in a fresh one, and the next routines still run
            logger.exception(f"[Routines] {routine.id} crashed")
            await _record_crash(session_factory, routine)
    return len(due)


async def _record_crash(session_factory, routine: _Due) -> None:
    try:
        async with session_factory() as db:
            row = await db.get(Routine, routine.id)
            if row is not None:
                await record_run(
                    db, row, status="failed", ran_at=datetime.now(timezone.utc),
                    text=FAILED[detect_language(routine.instruction)],
                )
                await db.commit()
    except Exception:
        logger.exception(f"[Routines] {routine.id}: could not record the failed run")


async def _delete_old_runs(now: datetime, session_factory=None) -> None:
    async with (session_factory or async_session)() as db:
        deleted = await delete_old_runs(db, now)
    if deleted:
        logger.info(f"[Routines] Deleted {deleted} runs older than 90 days")


async def run_routines_loop(redis_client, shutdown_event: asyncio.Event | None = None):
    logger.info("[Routines] Loop started")
    cleaned_on = None
    while not (shutdown_event and shutdown_event.is_set()):
        now = datetime.now(timezone.utc)
        try:
            ran = await run_due_routines(now, redis_client=redis_client)
            if ran:
                logger.info(f"[Routines] Ran {ran}")
            if cleaned_on != now.date():
                await _delete_old_runs(now)
                cleaned_on = now.date()
        except Exception:
            logger.exception("[Routines] Loop iteration failed")
        if await sleep_or_shutdown(LOOP_INTERVAL_S, shutdown_event):
            return
