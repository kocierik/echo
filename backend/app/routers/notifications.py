"""Notifications the phone schedules: /notifications/upcoming (see services/notifications).

POST sends the iPhone calendar's next events along, for briefings before those meetings
too; GET (older apps) uses Google Calendar only. What is handed out, and the briefings
switch, are written down (services/notice_ledger.py) for the briefs sent at once.
"""

import logging
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.composio_provider import get_action_provider
from app.actions.provider import ActionProviderError
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.services.notice_ledger import given_per_day, record_scheduled, set_briefings
from app.services.notifications import coming_up, phone_event, upcoming_notices

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/notifications", tags=["notifications"])


class NoticeOut(BaseModel):
    key: str
    kind: str
    fire_at: datetime
    title: str
    body: str
    target: str


class UpcomingOut(BaseModel):
    notifications: list[NoticeOut]


class PhoneAttendee(BaseModel):
    name: str | None = Field(default=None, max_length=200)
    email: str | None = Field(default=None, max_length=320)


class PhoneEvent(BaseModel):
    """An event of the iPhone's calendar, read by the app with EventKit."""

    id: str = Field(max_length=300)
    title: str = Field(default="", max_length=500)
    start: datetime
    all_day: bool = False
    notes: str | None = Field(default=None, max_length=4000)
    attendees: list[PhoneAttendee] = Field(default_factory=list, max_length=100)


class UpcomingRequest(BaseModel):
    briefings: bool = True
    promises: bool = True
    evening: bool = False
    hours: int = Field(default=36, ge=1, le=72)
    phone_events: list[PhoneEvent] = Field(default_factory=list, max_length=300)


class ComingUpRequest(BaseModel):
    phone_events: list[PhoneEvent] = Field(default_factory=list, max_length=300)


class ComingUpEvent(BaseModel):
    title: str
    start: datetime


class ComingUpOut(BaseModel):
    event: ComingUpEvent | None = None
    recap: str | None = None


async def _upcoming(
    db: AsyncSession, redis, user_id: uuid.UUID, request: UpcomingRequest
) -> UpcomingOut:
    try:
        provider = get_action_provider() if request.briefings else None
    except ActionProviderError:
        provider = None  # no Composio: briefings from the iPhone's calendar only
    now = datetime.now(timezone.utc)
    until = now + timedelta(hours=request.hours)
    try:
        taken = await given_per_day(redis, user_id, now, until)
    except Exception:
        logger.warning("Notice ledger unreadable", exc_info=True)
        taken = {}
    notices = await upcoming_notices(
        db,
        user_id,
        now=now,
        hours=request.hours,
        briefings=request.briefings,
        promises=request.promises,
        evening=request.evening,
        provider=provider,
        phone_events=[phone_event(e.model_dump()) for e in request.phone_events],
        taken=taken,
    )
    try:
        await record_scheduled(redis, user_id, notices, now, until)
        await set_briefings(redis, user_id, request.briefings)
    except Exception:
        logger.warning("Notice ledger not updated", exc_info=True)
    return UpcomingOut(notifications=[NoticeOut(**n.__dict__) for n in notices])


@router.get("/upcoming", response_model=UpcomingOut)
async def upcoming(
    request: Request,
    briefings: bool = True,
    promises: bool = True,
    evening: bool = False,
    hours: int = Query(default=36, ge=1, le=72),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The few worth sending in the next `hours`; the app replaces what it scheduled."""
    body = UpcomingRequest(briefings=briefings, promises=promises, evening=evening, hours=hours)
    return await _upcoming(db, request.app.state.redis, user_id, body)


@router.post("/upcoming", response_model=UpcomingOut)
async def upcoming_with_phone_events(
    body: UpcomingRequest,
    request: Request,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """As GET, with the iPhone calendar's next events for briefings."""
    return await _upcoming(db, request.app.state.redis, user_id, body)


@router.post("/coming-up", response_model=ComingUpOut)
async def what_is_coming_up(
    body: ComingUpRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Today's "coming up" card: the iPhone calendar's next event within the hour, and what
    was said last time with its people or about its title."""
    events = [phone_event(e.model_dump()) for e in body.phone_events]
    soon = await coming_up(db, user_id, events, datetime.now(timezone.utc))
    if soon is None:
        return ComingUpOut()
    return ComingUpOut(event=ComingUpEvent(title=soon.title, start=soon.start), recap=soon.recap)
