"""Routines API: the user's routines, to see, pause, resume and remove.

They are created by asking Echo (the action agent's routine tools), or added from the
catalog of ready-made ones (services/routine_catalog.py).
"""

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.assistant import Assistant
from app.models.routine import Routine
from app.models.user import User
from app.services.language import SUPPORTED_LANGUAGES
from app.services.routine_catalog import BY_KEY, CATALOG, DEFAULT_LANGUAGE
from app.services.routines import (
    add_routine,
    describe_schedule,
    next_run,
    validate_schedule,
)

router = APIRouter(prefix="/routines", tags=["routines"])


class RoutineOut(BaseModel):
    id: uuid.UUID
    instruction: str
    schedule: dict
    schedule_text: str
    # "always" | "only_if" | "only_new"
    mode: str
    timezone: str
    active: bool
    next_run_at: datetime
    last_run_at: datetime | None
    last_status: str | None
    last_answer: str | None
    source: str
    created_at: datetime
    # The assistant it runs as (made in its chat); none: plain Echo
    assistant_id: uuid.UUID | None = None
    assistant_name: str | None = None
    assistant_emoji: str | None = None
    # The catalog entry it was added from; none when asked for in words
    catalog_key: str | None = None


class CatalogEntryOut(BaseModel):
    key: str
    emoji: str
    title: str
    summary: str
    instruction: str
    # What a run could say, to show before adding it
    example: str
    schedule: dict
    schedule_text: str
    mode: str
    # Already added: that routine (to show it as added, or remove it)
    routine_id: uuid.UUID | None = None


class CatalogAdd(BaseModel):
    # "HH:MM" in place of the entry's own time
    time: str | None = None


class RoutineUpdate(BaseModel):
    active: bool


def _out(routine: Routine, assistant: Assistant | None = None) -> RoutineOut:
    return RoutineOut(
        id=routine.id,
        instruction=routine.instruction,
        schedule=routine.schedule,
        schedule_text=describe_schedule(routine.schedule),
        mode=routine.mode,
        timezone=routine.timezone,
        active=routine.active,
        next_run_at=routine.next_run_at,
        last_run_at=routine.last_run_at,
        last_status=routine.last_status,
        last_answer=routine.last_answer,
        source=routine.source,
        created_at=routine.created_at,
        assistant_id=assistant.id if assistant else None,
        assistant_name=assistant.name if assistant else None,
        assistant_emoji=assistant.emoji if assistant else None,
        catalog_key=routine.catalog_key,
    )


async def _assistant_of(db: AsyncSession, routine: Routine) -> Assistant | None:
    return await db.get(Assistant, routine.assistant_id) if routine.assistant_id else None


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
    routines = list(routines)
    ids = {r.assistant_id for r in routines if r.assistant_id is not None}
    assistants = (
        {a.id: a for a in await db.scalars(select(Assistant).where(Assistant.id.in_(ids)))}
        if ids
        else {}
    )
    return [_out(routine, assistants.get(routine.assistant_id)) for routine in routines]


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
    return _out(routine, await _assistant_of(db, routine))


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


async def _language(db: AsyncSession, user_id: uuid.UUID) -> str:
    user = await db.get(User, user_id)
    language = user.language if user is not None else DEFAULT_LANGUAGE
    return language if language in SUPPORTED_LANGUAGES else DEFAULT_LANGUAGE


async def _added(db: AsyncSession, user_id: uuid.UUID) -> dict[str, Routine]:
    rows = await db.scalars(
        select(Routine).where(Routine.user_id == user_id, Routine.catalog_key.isnot(None))
    )
    return {routine.catalog_key: routine for routine in rows}


@router.get("/catalog", response_model=list[CatalogEntryOut])
async def list_catalog(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The ready-made routines, in the user's language, with the ones already added."""
    language = await _language(db, user_id)
    added = await _added(db, user_id)
    entries = []
    for entry in CATALOG:
        title, summary, instruction, example = entry.text(language)
        routine = added.get(entry.key)
        entries.append(CatalogEntryOut(
            key=entry.key, emoji=entry.emoji, title=title, summary=summary,
            instruction=instruction, example=example, schedule=entry.schedule,
            schedule_text=describe_schedule(entry.schedule), mode=entry.mode,
            routine_id=routine.id if routine else None,
        ))
    return entries


@router.post("/catalog/{key}", response_model=RoutineOut, status_code=201)
async def add_from_catalog(
    key: str,
    body: CatalogAdd,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Adds a catalog entry as one of the user's routines (once: added again, the same)."""
    entry = BY_KEY.get(key)
    if entry is None:
        raise HTTPException(status_code=404, detail="Not in the catalog")
    existing = (await _added(db, user_id)).get(key)
    if existing is not None:
        return _out(existing)
    schedule = dict(entry.schedule)
    if body.time:
        schedule["time"] = body.time
    _, _, instruction, _ = entry.text(await _language(db, user_id))
    try:
        routine = await add_routine(
            db, user_id, instruction=instruction, schedule=validate_schedule(schedule),
            mode=entry.mode, source="catalog", catalog_key=key,
        )
    except ValueError as exc:  # a wrong time, or the plan's limit
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    await db.commit()
    return _out(routine)

