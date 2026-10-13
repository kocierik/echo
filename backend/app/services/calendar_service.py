"""Google Calendar service — create, read, update, delete events."""

import logging
import uuid
from datetime import datetime, timedelta

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.integration import Integration

logger = logging.getLogger(__name__)

CALENDAR_API = "https://www.googleapis.com/calendar/v3"


async def get_calendar_token(db: AsyncSession, user_id: uuid.UUID) -> str | None:
    """Get a valid access token for the user's Google Calendar, refreshing if needed."""
    result = await db.execute(
        select(Integration)
        .where(Integration.user_id == user_id)
        .where(Integration.provider == "google_calendar")
        .where(Integration.enabled.is_(True))
    )
    integration = result.scalar_one_or_none()
    if not integration:
        return None

    config = integration.config
    access_token = config.get("access_token")
    refresh_token = config.get("refresh_token")

    # Try existing token first
    if access_token:
        async with httpx.AsyncClient() as client:
            resp = await client.get(
                f"{CALENDAR_API}/calendars/primary",
                headers={"Authorization": f"Bearer {access_token}"},
            )
            if resp.status_code == 200:
                return access_token

    # Token expired — refresh
    if refresh_token:
        new_token = await _refresh_token(refresh_token)
        if new_token:
            integration.config = {**config, "access_token": new_token}
            await db.commit()
            return new_token

    return None


async def _refresh_token(refresh_token: str) -> str | None:
    """Refresh Google access token."""
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            "https://oauth2.googleapis.com/token",
            data={
                "client_id": settings.google_client_id,
                "client_secret": settings.google_client_secret,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
        )
        if resp.status_code == 200:
            return resp.json().get("access_token")
        logger.error(f"[Calendar] Token refresh failed: {resp.text[:100]}")
        return None


async def list_events(
    db: AsyncSession, user_id: uuid.UUID, date_from: str | None = None, date_to: str | None = None, days: int = 7
) -> list[dict] | None:
    """List events for a specific date range, or next N days if no range given."""
    token = await get_calendar_token(db, user_id)
    if not token:
        return None

    if date_from:
        time_min = f"{date_from}T00:00:00Z"
        # date_to is end of that day
        end_date = date_to or date_from
        time_max = f"{end_date}T23:59:59Z"
    else:
        now = datetime.utcnow().isoformat() + "Z"
        time_min = now
        time_max = (datetime.utcnow() + timedelta(days=days)).isoformat() + "Z"

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{CALENDAR_API}/calendars/primary/events",
            headers={"Authorization": f"Bearer {token}"},
            params={
                "timeMin": time_min,
                "timeMax": time_max,
                "singleEvents": "true",
                "orderBy": "startTime",
                "maxResults": "20",
            },
        )
        if resp.status_code != 200:
            logger.error(f"[Calendar] List failed: {resp.status_code}")
            return None

        data = resp.json()
        events = []
        for item in data.get("items", []):
            start = item.get("start", {})
            events.append({
                "id": item["id"],
                "summary": item.get("summary", "(no title)"),
                "start": start.get("dateTime") or start.get("date"),
                "location": item.get("location"),
            })
        return events


async def create_event(
    db: AsyncSession,
    user_id: uuid.UUID,
    summary: str,
    date: str,
    time: str | None = None,
    location: str | None = None,
    description: str | None = None,
    duration_minutes: int = 60,
) -> dict | None:
    """Create a calendar event. Returns the created event or None on failure.

    Args:
        duration_minutes: Duration of timed events in minutes (default 60).
                          Ignored for all-day events (no time specified).
    """
    token = await get_calendar_token(db, user_id)
    if not token:
        return None

    body: dict = {"summary": summary}
    if description:
        body["description"] = description
    if location:
        body["location"] = location

    if time:
        start_dt = datetime.fromisoformat(f"{date}T{time}:00")
        end_dt = start_dt + timedelta(minutes=duration_minutes)
        body["start"] = {"dateTime": start_dt.isoformat(), "timeZone": "Europe/Rome"}
        body["end"] = {"dateTime": end_dt.isoformat(), "timeZone": "Europe/Rome"}
    else:
        body["start"] = {"date": date}
        body["end"] = {"date": date}

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{CALENDAR_API}/calendars/primary/events",
            headers={"Authorization": f"Bearer {token}"},
            json=body,
        )
        if resp.status_code in (200, 201):
            logger.info(f"[Calendar] Created: {summary}")
            return resp.json()
        logger.error(f"[Calendar] Create failed ({resp.status_code}): {resp.text[:200]}")
        return None


async def update_event(
    db: AsyncSession,
    user_id: uuid.UUID,
    event_id: str,
    summary: str | None = None,
    date: str | None = None,
    time: str | None = None,
    location: str | None = None,
    duration_minutes: int = 60,
) -> dict | None:
    """Update an existing calendar event.

    Args:
        duration_minutes: Duration of timed events in minutes (default 60).
                          Ignored for all-day events (no time specified).
    """
    token = await get_calendar_token(db, user_id)
    if not token:
        return None

    body: dict = {}
    if summary:
        body["summary"] = summary
    if location:
        body["location"] = location
    if date and time:
        start_dt = datetime.fromisoformat(f"{date}T{time}:00")
        end_dt = start_dt + timedelta(minutes=duration_minutes)
        body["start"] = {"dateTime": start_dt.isoformat(), "timeZone": "Europe/Rome"}
        body["end"] = {"dateTime": end_dt.isoformat(), "timeZone": "Europe/Rome"}
    elif date:
        body["start"] = {"date": date}
        body["end"] = {"date": date}

    if not body:
        return None

    async with httpx.AsyncClient() as client:
        resp = await client.patch(
            f"{CALENDAR_API}/calendars/primary/events/{event_id}",
            headers={"Authorization": f"Bearer {token}"},
            json=body,
        )
        if resp.status_code == 200:
            logger.info(f"[Calendar] Updated: {event_id}")
            return resp.json()
        logger.error(f"[Calendar] Update failed ({resp.status_code}): {resp.text[:200]}")
        return None


async def delete_event(
    db: AsyncSession, user_id: uuid.UUID, event_id: str
) -> bool:
    """Delete a calendar event."""
    token = await get_calendar_token(db, user_id)
    if not token:
        return False

    async with httpx.AsyncClient() as client:
        resp = await client.delete(
            f"{CALENDAR_API}/calendars/primary/events/{event_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
        if resp.status_code in (200, 204):
            logger.info(f"[Calendar] Deleted: {event_id}")
            return True
        logger.error(f"[Calendar] Delete failed ({resp.status_code})")
        return False
