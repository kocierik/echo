"""Places visited API: the phone's stays (Profile → Places visited, off by default), the
visits listed by day with the conversations held there, and the deletes.

The phone sends its stays in batches, like segments: each when it starts and again when
it ends, under the same key (services/places.py keeps one visit per key). Outside
assistants (MCP) have no way to these.
"""

import uuid
from collections import defaultdict
from datetime import date, datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.conversation import Conversation
from app.models.place_visit import PlaceVisit
from app.services import places
from app.services.temporal import conversation_overlaps

router = APIRouter(prefix="/places", tags=["places"])

MAX_BATCH = 200


class StayIn(BaseModel):
    key: str = Field(min_length=1, max_length=80)
    arrived_at: datetime
    left_at: datetime | None = None
    latitude: float
    longitude: float
    accuracy_m: float | None = None
    name: str | None = Field(default=None, max_length=500)
    address: str | None = Field(default=None, max_length=500)


class StaysIn(BaseModel):
    source: Literal["ios", "android"]
    visits: list[StayIn] = Field(max_length=MAX_BATCH)


class StaysResult(BaseModel):
    kept: int
    dropped: int


class VisitConversation(BaseModel):
    id: uuid.UUID
    title: str | None


class VisitOut(BaseModel):
    id: uuid.UUID
    arrived_at: datetime
    # None while the user is still there
    left_at: datetime | None
    latitude: float
    longitude: float
    name: str | None
    address: str | None
    # The conversations held there, in time order
    conversations: list[VisitConversation]


class VisitPage(BaseModel):
    visits: list[VisitOut]
    # Older visits after the last one ("before" = its arrived_at)
    more: bool


class Deleted(BaseModel):
    deleted: int


def _utc(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


@router.post("/visits", response_model=StaysResult)
async def post_visits(
    body: StaysIn,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The phone's stays; the short, vague or impossible ones are not kept."""
    stays = [
        places.VisitIn(
            key=stay.key,
            arrived_at=_utc(stay.arrived_at),
            left_at=_utc(stay.left_at) if stay.left_at else None,
            latitude=stay.latitude,
            longitude=stay.longitude,
            accuracy_m=stay.accuracy_m,
            name=stay.name,
            address=stay.address,
        )
        for stay in body.visits
    ]
    kept, dropped = await places.record_visits(
        db, user_id, stays, source=body.source, now=datetime.now(timezone.utc)
    )
    await db.commit()
    return StaysResult(kept=kept, dropped=dropped)


async def _conversations_at(
    db: AsyncSession, user_id: uuid.UUID, visits: list[PlaceVisit], now: datetime
) -> dict[uuid.UUID, list[VisitConversation]]:
    """Per visit: the conversations whose place it is."""
    if not visits:
        return {}
    start = min(v.arrived_at for v in visits)
    end = max(v.left_at or now for v in visits)
    rows = (
        await db.execute(
            select(Conversation.id, Conversation.title, Conversation.started_at,
                   Conversation.ended_at)
            .where(Conversation.user_id == user_id, *conversation_overlaps(start, end))
            .order_by(Conversation.started_at)
        )
    ).all()
    titles = {row.id: row.title for row in rows}
    found = await places.places_of(
        db, user_id, [(row.id, row.started_at, row.ended_at) for row in rows], now=now
    )
    shown = {v.id for v in visits}
    held: dict[uuid.UUID, list[VisitConversation]] = defaultdict(list)
    for row in rows:
        visit = found.get(row.id)
        if visit is not None and visit.id in shown:
            held[visit.id].append(VisitConversation(id=row.id, title=titles[row.id]))
    return held


@router.get("/visits", response_model=VisitPage)
async def list_visits(
    before: datetime | None = None,
    limit: int = Query(100, ge=1, le=200),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The visits, newest first; the app groups them by day."""
    now = datetime.now(timezone.utc)
    query = select(PlaceVisit).where(PlaceVisit.user_id == user_id)
    if before is not None:
        query = query.where(PlaceVisit.arrived_at < _utc(before))
    rows = await db.scalars(query.order_by(PlaceVisit.arrived_at.desc()))
    counting = []
    for visit in rows:
        if places.counts(visit, now):
            counting.append(visit)
        if len(counting) > limit:
            break
    page = counting[:limit]
    held = await _conversations_at(db, user_id, page, now)
    return VisitPage(
        visits=[
            VisitOut(
                id=v.id,
                arrived_at=v.arrived_at,
                left_at=v.left_at,
                latitude=v.latitude,
                longitude=v.longitude,
                name=v.name,
                address=v.address,
                conversations=held.get(v.id, []),
            )
            for v in page
        ],
        more=len(counting) > limit,
    )


@router.delete("/visits/{visit_id}", status_code=204)
async def delete_visit(
    visit_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    if not await places.delete_visit(db, user_id, visit_id):
        raise HTTPException(status_code=404, detail="Visit not found")
    await db.commit()
    return Response(status_code=204)


@router.delete("/days/{day}", response_model=Deleted)
async def delete_day(
    day: date,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The visits that started on that day (the user's time zone)."""
    deleted = await places.delete_day(db, user_id, day)
    await db.commit()
    return Deleted(deleted=deleted)


@router.delete("/visits", response_model=Deleted)
async def delete_all_visits(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Every visit kept ("Delete all places", or turning the option off)."""
    deleted = await places.delete_all(db, user_id)
    await db.commit()
    return Deleted(deleted=deleted)
