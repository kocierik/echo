"""Routines API: the user's routines, to see, pause, resume and remove.

They are created by asking Echo (the action agent's routine tools), never here.
"""

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.routine import Routine
from app.services.routines import describe_schedule, next_run

router = APIRouter(prefix="/routines", tags=["routines"])


class RoutineOut(BaseModel):
    id: uuid.UUID
    instruction: str
    schedule: dict
    schedule_text: str
    timezone: str
    active: bool
    next_run_at: datetime
    last_run_at: datetime | None
    last_status: str | None
    last_answer: str | None
    source: str
    created_at: datetime


class RoutineUpdate(BaseModel):
    active: bool


def _out(routine: Routine) -> RoutineOut:
    return RoutineOut(
        id=routine.id,
        instruction=routine.instruction,
        schedule=routine.schedule,
        schedule_text=describe_schedule(routine.schedule),
        timezone=routine.timezone,
        active=routine.active,
        next_run_at=routine.next_run_at,
        last_run_at=routine.last_run_at,
        last_status=routine.last_status,
        last_answer=routine.last_answer,
        source=routine.source,
        created_at=routine.created_at,
    )


async def _own(db: AsyncSession, user_id: uuid.UUID, routine_id: uuid.UUID) -> Routine:
    routine = await db.get(Routine, routine_id)
    if routine is None or routine.user_id != user_id:
        raise HTTPException(status_code=404, detail="Routine not found")
    return routine


@router.get("", response_model=list[RoutineOut])
async def list_routines(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    routines = await db.scalars(
        select(Routine).where(Routine.user_id == user_id).order_by(Routine.created_at.desc())
    )
    return [_out(routine) for routine in routines]


@router.patch("/{routine_id}", response_model=RoutineOut)
async def update_routine(
    routine_id: uuid.UUID,
    body: RoutineUpdate,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    routine = await _own(db, user_id, routine_id)
    if body.active and not routine.active:
        # From now: the days it was paused are not run late
        routine.next_run_at = next_run(
            routine.schedule, routine.timezone, datetime.now(timezone.utc)
        )
    routine.active = body.active
    await db.commit()
    return _out(routine)


@router.delete("/{routine_id}", status_code=204)
async def delete_routine(
    routine_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    routine = await _own(db, user_id, routine_id)
    await db.delete(routine)
    await db.commit()
    return Response(status_code=204)
