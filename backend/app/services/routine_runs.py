"""A routine's runs in the database: recording one, what an `only_new` routine already
reported, and deleting runs older than 90 days (workers/routines.py)."""

import uuid
from datetime import datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.routine import Routine
from app.models.routine_run import RoutineRun

KEEP_DAYS = 90
# The newest reported items listed for the request; the filter uses all of them (seen_keys)
SEEN_LIMIT = 200


async def seen_items(db: AsyncSession, routine_id: uuid.UUID) -> list[dict]:
    """The items this routine's runs reported, newest first, each key once."""
    runs = await db.scalars(
        select(RoutineRun)
        .where(RoutineRun.routine_id == routine_id, RoutineRun.items != [])
        .order_by(RoutineRun.ran_at.desc())
    )
    seen: list[dict] = []
    keys: set[str] = set()
    for run in runs:
        for item in run.items or []:
            if item.get("key") in keys:
                continue
            keys.add(item.get("key"))
            seen.append(item)
            if len(seen) >= SEEN_LIMIT:
                return seen
    return seen


async def seen_keys(db: AsyncSession, routine_id: uuid.UUID) -> set[str]:
    """Every key this routine's kept runs reported (90 days): what an only_new run drops."""
    rows = await db.scalars(
        select(RoutineRun.items).where(
            RoutineRun.routine_id == routine_id, RoutineRun.items != []
        )
    )
    return {item.get("key") for items in rows for item in items or [] if item.get("key")}


async def record_run(
    db: AsyncSession,
    routine: Routine,
    *,
    status: str,
    ran_at: datetime,
    text: str | None = None,
    sources: list[dict] | None = None,
    items: list[dict] | None = None,
) -> RoutineRun:
    """Add the run and make it the routine's latest. Does not commit."""
    run = RoutineRun(
        routine_id=routine.id,
        user_id=routine.user_id,
        ran_at=ran_at,
        status=status,
        text=text,
        sources=sources or [],
        items=items or [],
    )
    db.add(run)
    routine.last_run_at = ran_at
    routine.last_status = status
    if text:
        routine.last_answer = text
    return run


async def delete_old_runs(db: AsyncSession, now: datetime) -> int:
    """Delete the runs older than 90 days. Commits."""
    result = await db.execute(
        delete(RoutineRun).where(RoutineRun.ran_at < now - timedelta(days=KEEP_DAYS))
    )
    await db.commit()
    return result.rowcount or 0
