"""Notifications the phone schedules: /notifications/upcoming (see services/notifications).

POST sends the iPhone calendar's next events along, for briefings before those meetings
too; GET (older apps) uses Google Calendar only.
"""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.composio_provider import get_action_provider
from app.actions.provider import ActionProviderError
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.services.notifications import phone_event, upcoming_notices

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


async def _upcoming(
    db: AsyncSession, user_id: uuid.UUID, request: UpcomingRequest
) -> UpcomingOut:
    try:
        provider = get_action_provider() if request.briefings else None
    except ActionProviderError:
        provider = None  # no Composio: briefings from the iPhone's calendar only
    notices = await upcoming_notices(
        db,
        user_id,
        hours=request.hours,
        briefings=request.briefings,
        promises=request.promises,
        evening=request.evening,
        provider=provider,
        phone_events=[phone_event(e.model_dump()) for e in request.phone_events],
    )
    return UpcomingOut(notifications=[NoticeOut(**n.__dict__) for n in notices])


@router.get("/upcoming", response_model=UpcomingOut)
async def upcoming(
    briefings: bool = True,
    promises: bool = True,
    evening: bool = False,
    hours: int = Query(default=36, ge=1, le=72),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The few worth sending in the next `hours`; the app replaces what it scheduled."""
    request = UpcomingRequest(briefings=briefings, promises=promises, evening=evening, hours=hours)
    return await _upcoming(db, user_id, request)


@router.post("/upcoming", response_model=UpcomingOut)
async def upcoming_with_phone_events(
    body: UpcomingRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """As GET, with the iPhone calendar's next events for briefings."""
    return await _upcoming(db, user_id, body)
