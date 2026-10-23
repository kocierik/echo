"""Saved API: the app's Saved page (Today → Saved), a list, a thing and its moment.

Things are saved by asking Echo (the agent's Saved tools), never here; the app moves and
removes them ("Found it", "Remove from Saved"), and sends the place the phone could not
read while in the background (`PUT /saved/items/{id}/place`).
"""

import uuid
from datetime import datetime, time, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.core.timezone import user_zone
from app.models.conversation import Conversation
from app.models.photo import Photo
from app.models.saved import SavedItem, SavedList
from app.models.segment import Segment
from app.services import saved
from app.services.phone_location import valid_place

router = APIRouter(prefix="/saved", tags=["saved"])

# Things shown under each list on the Saved page ("All N" opens the rest)
SHOWN_PER_LIST = 6
SEARCH_LIMIT = 30


class SavedItemOut(BaseModel):
    id: uuid.UUID
    list_id: uuid.UUID
    list: str
    latest_only: bool
    keep_days: int | None
    title: str
    details: str | None
    fields: dict
    photo_id: uuid.UUID | None
    place: dict | None
    people: list[dict]
    source: str
    saved_at: datetime
    updated_at: datetime


class WeekSum(BaseModel):
    count: int
    totals: dict[str, float]


class SavedListOut(BaseModel):
    id: uuid.UUID
    name: str
    latest_only: bool
    keep_days: int | None
    count: int
    updated_at: datetime
    items: list[SavedItemOut] = []
    # This week's total of the list's amounts, when it has any
    week_sum: WeekSum | None = None


class SavedOverview(BaseModel):
    total: int
    latest_list: str | None
    # "Only the latest" things with a place (the car): cards first
    places: list[SavedItemOut]
    lists: list[SavedListOut]


class SavedSearch(BaseModel):
    results: list[SavedItemOut]


class ListChoice(BaseModel):
    id: uuid.UUID
    name: str
    count: int
    latest_only: bool
    keep_days: int | None


class SavedListDetail(BaseModel):
    list: ListChoice
    items: list[SavedItemOut]


class MomentConversation(BaseModel):
    id: uuid.UUID
    title: str | None
    started_at: datetime
    duration_s: int


class Moment(BaseModel):
    at: datetime
    people: list[dict]
    # The request as said ("its line")
    request: str | None
    conversation: MomentConversation | None


class SavedItemDetail(SavedItemOut):
    # What Echo read on the photo
    photo_text: str | None
    moment: Moment


class MoveBody(BaseModel):
    list: str = Field(min_length=1, max_length=saved.MAX_LIST_NAME)


class PlaceBody(BaseModel):
    latitude: float
    longitude: float
    accuracy_m: float | None = None
    address: str | None = Field(default=None, max_length=500)


def _out(item: SavedItem) -> SavedItemOut:
    return SavedItemOut(
        id=item.id,
        list_id=item.list_id,
        list=item.list.name,
        latest_only=item.list.latest_only,
        keep_days=item.list.keep_days,
        title=item.title,
        details=item.details,
        fields=item.fields or {},
        photo_id=item.photo_id,
        place=item.place,
        people=item.people or [],
        source=item.source,
        saved_at=item.created_at,
        updated_at=item.updated_at,
    )


def _week_start() -> datetime:
    today = datetime.now(user_zone()).date()
    monday = today - timedelta(days=today.weekday())
    return datetime.combine(monday, time.min, tzinfo=user_zone())


async def _own_item(db: AsyncSession, user_id: uuid.UUID, item_id: uuid.UUID) -> SavedItem:
    item = await db.get(SavedItem, item_id)
    if item is None or item.user_id != user_id:
        raise HTTPException(status_code=404, detail="Saved thing not found")
    return item


async def _counts(db: AsyncSession, user_id: uuid.UUID) -> list[tuple[SavedList, int]]:
    rows = await db.execute(
        select(SavedList, func.count(SavedItem.id))
        .outerjoin(SavedItem, SavedItem.list_id == SavedList.id)
        .where(SavedList.user_id == user_id)
        .group_by(SavedList.id)
        .order_by(SavedList.updated_at.desc())
    )
    return list(rows.all())


@router.get("", response_model=SavedOverview | SavedSearch)
async def saved_overview(
    q: str | None = Query(default=None, max_length=200),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The Saved page; with `q`, the things matching its words instead."""
    if q is not None and q.strip():
        found = await saved.find_items(db, user_id, query=q, limit=SEARCH_LIMIT)
        return SavedSearch(results=[_out(item) for item in found])

    items = list(
        (
            await db.scalars(
                select(SavedItem)
                .where(SavedItem.user_id == user_id)
                .order_by(SavedItem.created_at.desc())
            )
        ).unique()
    )
    places = [i for i in items if i.list.latest_only and i.place]
    shown_as_cards = {i.id for i in places}
    lists = []
    week = _week_start()
    for lst, count in await _counts(db, user_id):
        own = [i for i in items if i.list_id == lst.id]
        if not own or all(i.id in shown_as_cards for i in own):
            continue
        week_sum = None
        if any(saved.parse_amount((i.fields or {}).get("amount"))[0] is not None for i in own):
            total = await saved.sum_items(db, user_id, list_name=lst.name, date_from=week)
            if total["count"]:
                week_sum = WeekSum(count=total["count"], totals=total["totals"])
        lists.append(SavedListOut(
            id=lst.id,
            name=lst.name,
            latest_only=lst.latest_only,
            keep_days=lst.keep_days,
            count=count,
            updated_at=lst.updated_at,
            items=[_out(i) for i in own[:SHOWN_PER_LIST]],
            week_sum=week_sum,
        ))
    latest = max(
        (i.list for i in items), key=lambda lst: lst.updated_at, default=None
    )
    return SavedOverview(
        total=len(items),
        latest_list=latest.name if latest else None,
        places=[_out(i) for i in places],
        lists=lists,
    )


@router.get("/lists", response_model=list[ListChoice])
async def saved_lists(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Every list (empty ones too), for "Move to…"."""
    return [
        ListChoice(
            id=lst.id, name=lst.name, count=count, latest_only=lst.latest_only,
            keep_days=lst.keep_days,
        )
        for lst, count in await _counts(db, user_id)
    ]


@router.get("/lists/{list_id}", response_model=SavedListDetail)
async def saved_list(
    list_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    lst = await db.get(SavedList, list_id)
    if lst is None or lst.user_id != user_id:
        raise HTTPException(status_code=404, detail="List not found")
    items = list(
        (
            await db.scalars(
                select(SavedItem)
                .where(SavedItem.list_id == lst.id)
                .order_by(SavedItem.created_at.desc())
            )
        ).unique()
    )
    return SavedListDetail(
        list=ListChoice(
            id=lst.id, name=lst.name, count=len(items), latest_only=lst.latest_only,
            keep_days=lst.keep_days,
        ),
        items=[_out(i) for i in items],
    )


async def _moment_conversation(db: AsyncSession, item: SavedItem) -> MomentConversation | None:
    conversation_id = item.conversation_id
    if conversation_id is None and item.segment_id is not None:
        # A voice request's segment, grouped into its conversation after the save
        conversation_id = await db.scalar(
            select(Segment.conversation_id).where(Segment.id == item.segment_id)
        )
    if conversation_id is None:
        return None
    conversation = await db.get(Conversation, conversation_id)
    if conversation is None:
        return None
    end = conversation.ended_at or conversation.started_at
    return MomentConversation(
        id=conversation.id,
        title=conversation.title,
        started_at=conversation.started_at,
        duration_s=int((end - conversation.started_at).total_seconds()),
    )


async def _detail(db: AsyncSession, item: SavedItem) -> SavedItemDetail:
    photo_text = None
    if item.photo_id is not None:
        photo_text = await db.scalar(select(Photo.description).where(Photo.id == item.photo_id))
    return SavedItemDetail(
        **_out(item).model_dump(),
        photo_text=photo_text,
        moment=Moment(
            at=item.created_at,
            people=item.people or [],
            request=item.request_text,
            conversation=await _moment_conversation(db, item),
        ),
    )


@router.get("/items/{item_id}", response_model=SavedItemDetail)
async def saved_item(
    item_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    return await _detail(db, await _own_item(db, user_id, item_id))


@router.patch("/items/{item_id}", response_model=SavedItemOut)
async def move_saved_item(
    item_id: uuid.UUID,
    body: MoveBody,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """"Move to…": to another list, started when new."""
    item = await _own_item(db, user_id, item_id)
    await saved.update_item(db, item, list_name=body.list)
    await db.commit()
    return _out(item)


@router.put("/items/{item_id}/place", response_model=SavedItemOut)
async def put_saved_place(
    item_id: uuid.UUID,
    body: PlaceBody,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The place the phone read once opened (it was in the background when asked)."""
    item = await _own_item(db, user_id, item_id)
    place = valid_place(body.model_dump())
    if place is None:
        raise HTTPException(status_code=422, detail="Not a place on Earth")
    await saved.update_item(db, item, place=place)
    await db.commit()
    return _out(item)


@router.delete("/items/{item_id}", status_code=204)
async def delete_saved_item(
    item_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """"Found it" and "Remove from Saved": the thing only, never its photo."""
    item = await _own_item(db, user_id, item_id)
    await saved.remove_item(db, item)
    await db.commit()
    return Response(status_code=204)
