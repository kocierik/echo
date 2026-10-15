"""Notifications the phone schedules: GET /notifications/upcoming (see services/notifications)."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.composio_provider import get_action_provider
from app.actions.provider import ActionProviderError
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.services.notifications import upcoming_notices

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
    try:
        provider = get_action_provider() if briefings else None
    except ActionProviderError:
        provider = None  # no Composio: no calendar, no briefings
    notices = await upcoming_notices(
        db,
        user_id,
        hours=hours,
        briefings=briefings,
        promises=promises,
        evening=evening,
        provider=provider,
    )
    return UpcomingOut(notifications=[NoticeOut(**n.__dict__) for n in notices])
