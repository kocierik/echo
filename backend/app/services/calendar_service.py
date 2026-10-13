"""Google Calendar service — create, read, update, delete events."""

import logging
import uuid
from datetime import date as date_cls
from datetime import datetime, timedelta, timezone
from datetime import time as time_cls
from difflib import SequenceMatcher

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.timezone import local_day_bounds, to_user_local_date
from app.models.integration import Integration

logger = logging.getLogger(__name__)

CALENDAR_API = "https://www.googleapis.com/calendar/v3"


def rfc3339_day_range(first_day: str, last_day: str) -> tuple[str, str]:
    """RFC 3339 [start, end) covering whole days in the user's timezone.

    Google's timeMax is exclusive, so the end is midnight after last_day.
    """
    start, _ = local_day_bounds(date_cls.fromisoformat(first_day))
    _, end = local_day_bounds(date_cls.fromisoformat(last_day))
    return start.isoformat(), end.isoformat()


def all_day_range(day: str) -> tuple[dict, dict]:
    """Start/end for an all-day event: Google expects an exclusive end date (next day)."""
    end_day = datetime.fromisoformat(day).date() + timedelta(days=1)
    return {"date": day}, {"date": end_day.isoformat()}


def timed_range(day: str, time: str, duration_minutes: int) -> tuple[dict, dict]:
    """Start/end for a timed event in the user's timezone.

    Args:
        day: ISO date (YYYY-MM-DD).
        time: Local start time (HH:MM or HH:MM:SS).
        duration_minutes: Event length in minutes.
    """
    start_dt = datetime.fromisoformat(f"{day}T{time}")
    end_dt = start_dt + timedelta(minutes=duration_minutes)
    timezone = settings.user_timezone
    return (
        {"dateTime": start_dt.isoformat(), "timeZone": timezone},
        {"dateTime": end_dt.isoformat(), "timeZone": timezone},
    )


def event_schedule_from_metadata(
    metadata: dict | None,
) -> tuple[str, str | None, int | None] | None:
    """Validated (date, start time, duration) from extracted entity metadata.

    Returns None when there is no usable ISO date. An invalid time is dropped
    (the event becomes all-day) and an invalid duration falls back to the default.
    """
    metadata = metadata or {}
    raw_day = metadata.get("event_date") or metadata.get("due_date")
    try:
        day = date_cls.fromisoformat(str(raw_day)).isoformat() if raw_day else None
    except ValueError:
        day = None
    if day is None:
        return None

    start_time = None
    raw_time = metadata.get("event_time")
    if raw_time:
        try:
            start_time = time_cls.fromisoformat(str(raw_time)).strftime("%H:%M")
        except ValueError:
            start_time = None

    duration = metadata.get("duration_minutes")
    if isinstance(duration, bool) or not isinstance(duration, int) or duration <= 0:
        duration = None
    return day, start_time, duration


def rescheduled_range(
    existing: dict,
    date: str | None = None,
    time: str | None = None,
    duration_minutes: int | None = None,
) -> tuple[dict, dict]:
    """New start/end for an existing Google event, filling gaps from the event itself.

    - only the time changes → same day, same duration;
    - only the date changes → same time and duration (all-day stays all-day);
    - only the duration changes → same start.
    """
    start = existing.get("start", {})
    end = existing.get("end", {})

    if "dateTime" in start:
        current_start = datetime.fromisoformat(start["dateTime"])
        current_end = datetime.fromisoformat(end.get("dateTime", start["dateTime"]))
        current_minutes = int((current_end - current_start).total_seconds() // 60)
        current_day = current_start.date().isoformat()
        current_time = current_start.strftime("%H:%M")
    else:
        current_minutes = None
        current_day = start.get("date")
        current_time = None

    new_day = date or current_day
    new_time = time or current_time
    if new_day is None:
        raise ValueError("Cannot reschedule an event without a date")
    if new_time is None:
        return all_day_range(new_day)

    minutes = (
        duration_minutes
        or current_minutes
        or settings.default_event_duration_minutes
    )
    return timed_range(new_day, new_time, minutes)


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
            # Flush only: callers (request handlers, the analysis pipeline) own the
            # transaction, and committing here would persist their partial work.
            await db.flush()
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
    db: AsyncSession,
    user_id: uuid.UUID,
    date_from: str | None = None,
    date_to: str | None = None,
    days: int = 7,
    max_results: int = 20,
) -> list[dict] | None:
    """List events for a specific date range, or next N days if no range given."""
    token = await get_calendar_token(db, user_id)
    if not token:
        return None

    if date_from:
        time_min, time_max = rfc3339_day_range(date_from, date_to or date_from)
    else:
        now = datetime.now(timezone.utc)
        time_min = now.isoformat()
        time_max = (now + timedelta(days=days)).isoformat()

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{CALENDAR_API}/calendars/primary/events",
            headers={"Authorization": f"Bearer {token}"},
            params={
                "timeMin": time_min,
                "timeMax": time_max,
                "singleEvents": "true",
                "orderBy": "startTime",
                "maxResults": str(max_results),
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


EVENT_SEARCH_DAYS = 14
EVENT_MATCH_THRESHOLD = 0.6


def _normalize_title(value: str) -> str:
    return " ".join(value.lower().split())


def match_events(events: list[dict], summary: str) -> list[dict]:
    """Events whose title matches the requested one, best match first."""
    wanted = _normalize_title(summary)
    if not wanted:
        return []
    scored = []
    for event in events:
        title = _normalize_title(event.get("summary") or "")
        if not title:
            continue
        if wanted == title:
            score = 2.0
        elif wanted in title or title in wanted:
            score = 1.0
        else:
            score = SequenceMatcher(None, wanted, title).ratio()
        if score >= EVENT_MATCH_THRESHOLD:
            scored.append((score, event))
    scored.sort(key=lambda item: item[0], reverse=True)
    return [event for _, event in scored]


async def find_events(
    db: AsyncSession,
    user_id: uuid.UUID,
    summary: str,
    day: str | None = None,
) -> list[dict] | None:
    """Find events by title on a day, or in the next EVENT_SEARCH_DAYS days.

    Returns None when Calendar is not connected, else the matches (best first).
    """
    if day:
        first_day = last_day = day
    else:
        today = to_user_local_date(datetime.now(timezone.utc))
        first_day = today.isoformat()
        last_day = (today + timedelta(days=EVENT_SEARCH_DAYS)).isoformat()
    events = await list_events(
        db, user_id, date_from=first_day, date_to=last_day, max_results=100
    )
    if events is None:
        return None
    return match_events(events, summary)


async def create_event(
    db: AsyncSession,
    user_id: uuid.UUID,
    summary: str,
    date: str,
    time: str | None = None,
    location: str | None = None,
    description: str | None = None,
    duration_minutes: int | None = None,
) -> dict | None:
    """Create a calendar event. Returns the created event or None on failure.

    Args:
        duration_minutes: Duration of timed events in minutes (default
                          settings.default_event_duration_minutes).
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
        body["start"], body["end"] = timed_range(
            date, time, duration_minutes or settings.default_event_duration_minutes
        )
    else:
        body["start"], body["end"] = all_day_range(date)

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
    duration_minutes: int | None = None,
) -> dict | None:
    """Update an existing calendar event.

    Only the given fields change. When rescheduling, a missing date or time is
    taken from the existing event and its duration is kept unless
    duration_minutes is given.
    """
    token = await get_calendar_token(db, user_id)
    if not token:
        return None

    body: dict = {}
    if summary:
        body["summary"] = summary
    if location:
        body["location"] = location

    async with httpx.AsyncClient() as client:
        if date or time or duration_minutes:
            existing = await client.get(
                f"{CALENDAR_API}/calendars/primary/events/{event_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
            if existing.status_code != 200:
                logger.error(f"[Calendar] Update lookup failed ({existing.status_code})")
                return None
            body["start"], body["end"] = rescheduled_range(
                existing.json(), date=date, time=time, duration_minutes=duration_minutes
            )

        if not body:
            return None

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
