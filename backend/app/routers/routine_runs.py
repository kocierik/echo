"""Routine runs API: what the user's routines found, for Today, Ask → Routines and Profile,
and "Ask about this", which puts one run into the thread with Echo.

Runs are written by workers/routines.py, never here.
"""

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.voice import get_or_create_voice_session
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.chat_session import ChatSession
from app.models.routine import Routine
from app.models.routine_run import RoutineRun
from app.services.routines import describe_schedule

router = APIRouter(prefix="/routine-runs", tags=["routines"])


class RunOut(BaseModel):
    id: uuid.UUID
    routine_id: uuid.UUID
    instruction: str
    mode: str
    schedule_text: str
    ran_at: datetime
    status: str
    text: str | None
    sources: list[dict]


class RunPage(BaseModel):
    items: list[RunOut]
    # Pass as `before` for the next page; None on the last one
    next_before: datetime | None


def _utc(when: datetime | None) -> datetime | None:
    if when is not None and when.tzinfo is None:
        return when.replace(tzinfo=timezone.utc)
    return when


def _out(run: RoutineRun, routine: Routine) -> RunOut:
    return RunOut(
        id=run.id,
        routine_id=run.routine_id,
        instruction=routine.instruction,
        mode=routine.mode,
        schedule_text=describe_schedule(routine.schedule),
        ran_at=run.ran_at,
        status=run.status,
        text=run.text,
        sources=run.sources or [],
    )


@router.get("", response_model=RunPage)
async def list_runs(
    routine_id: uuid.UUID | None = None,
    since: datetime | None = None,
    before: datetime | None = None,
    limit: int = Query(30, ge=1, le=100),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The user's runs, newest first: of one routine, from `since`, before `before`. A full
    page also takes the runs at its last run's time (two routines missed at 07:00), since
    the next page starts before that time."""
    query = (
        select(RoutineRun, Routine)
        .join(Routine, Routine.id == RoutineRun.routine_id)
        .where(RoutineRun.user_id == user_id)
        .order_by(RoutineRun.ran_at.desc(), RoutineRun.id.desc())
    )
    if routine_id is not None:
        query = query.where(RoutineRun.routine_id == routine_id)
    if since is not None:
        query = query.where(RoutineRun.ran_at >= _utc(since))
    if before is not None:
        query = query.where(RoutineRun.ran_at < _utc(before))
    rows = (await db.execute(query.limit(limit))).all()
    full = len(rows) == limit
    if full:
        last = rows[-1][0]
        rows += (await db.execute(
            query.where(RoutineRun.ran_at == last.ran_at, RoutineRun.id < last.id)
        )).all()
    items = [_out(run, routine) for run, routine in rows]
    return RunPage(items=items, next_before=items[-1].ran_at if full else None)


@router.post("/{run_id}/ask")
async def ask_about_run(
    run_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Add the run to the thread with Echo as Echo's message, once, so the next question
    has it in its history ("e domani?"); a routine of an assistant's goes to that
    assistant's latest chat instead. Not notified: the user asked for it."""
    run = await db.get(RoutineRun, run_id)
    if run is None or run.user_id != user_id:
        raise HTTPException(status_code=404, detail="Routine result not found")
    if not run.text:
        raise HTTPException(status_code=409, detail="This run has nothing to ask about")
    routine = await db.get(Routine, run.routine_id)
    if routine is not None and routine.assistant_id is not None:
        # Its assistant's latest chat (or a new one): the reply reaches it and its notes
        thread = await db.scalar(
            select(ChatSession)
            .where(
                ChatSession.user_id == user_id,
                ChatSession.assistant_id == routine.assistant_id,
                ChatSession.kind == "chat",
            )
            .order_by(ChatSession.updated_at.desc())
            .limit(1)
        )
        if thread is None:
            thread = ChatSession(
                id=uuid.uuid4(), user_id=user_id, title=routine.instruction[:80],
                messages=[], assistant_id=routine.assistant_id,
            )
            db.add(thread)
    else:
        thread = await get_or_create_voice_session(db, user_id)
    messages = thread.messages or []
    if not any(m.get("routine_run_id") == str(run.id) for m in messages):
        now = datetime.now(timezone.utc)
        # Reassign (not mutate) so SQLAlchemy sees the JSONB change
        thread.messages = [
            *messages,
            {
                "role": "assistant",
                "content": run.text,
                "timestamp": now.isoformat(),
                "routine_id": str(run.routine_id),
                "routine_run_id": str(run.id),
                "routine_schedule": describe_schedule(routine.schedule) if routine else "",
                "citations": run.sources or [],
                "notify": False,
                # The next question goes to the agent, which can look again ("e domani?")
                "actions": True,
            },
        ]
        thread.updated_at = now
    session_id = str(thread.id)
    await db.commit()
    return {"session_id": session_id}
