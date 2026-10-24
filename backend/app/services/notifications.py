"""The few notifications worth sending, computed here and scheduled by the phone.

The app has no push (no paid Apple account): each time it wakes (the wearable keeps it
awake through the day) it asks for what is coming and schedules it locally. Meetings come
from Google Calendar (Composio) and from the iPhone's calendar, whose next events the app
sends along. Rules:

- only when there is something to do: a briefing only for a meeting with someone you
  have open tasks, a promise or a recent conversation with; promises only on their day;
- at most MAX_PER_DAY a day (briefings first, then promises, then the evening recap);
- never in the quiet hours (QUIET_FROM to QUIET_UNTIL, user's time);
- the evening recap only when asked for, and only after a day with conversations.
"""

import logging
import time
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.provider import ActionProviderError
from app.core.timezone import local_day_bounds, user_zone
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.services.people import in_person_conversations, names_person, naming

logger = logging.getLogger(__name__)

MAX_PER_DAY = 3
QUIET_FROM = 22
QUIET_UNTIL = 8
PROMISE_HOUR = 9
EVENING_HOUR = 21
BRIEFING_BEFORE = timedelta(minutes=10)
RECENT_CONVERSATION = timedelta(days=30)
CALENDAR_CACHE_SECONDS = 15 * 60
CALENDAR_TOOL = "GOOGLECALENDAR_EVENTS_LIST"
PRIORITY = {"briefing": 0, "promises": 1, "evening": 2}

# user id -> (fetched at, events): the phone asks on every wake
_calendar_cache: dict[str, tuple[float, list[dict]]] = {}


@dataclass(frozen=True)
class Notice:
    key: str  # stable across requests: the phone replaces, never duplicates
    kind: str  # "briefing", "promises" or "evening"
    fire_at: datetime
    title: str
    body: str
    # What a tap opens: "person:<id>", "tasks" or "today"
    target: str


def _at_local(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=user_zone())


def is_quiet(moment: datetime) -> bool:
    hour = moment.astimezone(user_zone()).hour
    return hour >= QUIET_FROM or hour < QUIET_UNTIL


def select_notices(
    notices: list[Notice],
    now: datetime,
    until: datetime,
    taken: dict[date, int] | None = None,
) -> list[Notice]:
    """In the window, outside quiet hours, at most MAX_PER_DAY a day by priority.

    `taken`: per day, the notices already given (fired, or sent at once by
    services/person_brief.py), which count towards the limit.
    """
    kept: list[Notice] = []
    per_day: dict[date, int] = dict(taken or {})
    candidates = [n for n in notices if now < n.fire_at <= until and not is_quiet(n.fire_at)]
    for notice in sorted(candidates, key=lambda n: (PRIORITY[n.kind], n.fire_at)):
        day = notice.fire_at.astimezone(user_zone()).date()
        if per_day.get(day, 0) >= MAX_PER_DAY:
            continue
        per_day[day] = per_day.get(day, 0) + 1
        kept.append(notice)
    return sorted(kept, key=lambda n: n.fire_at)


async def open_promises(db: AsyncSession, user_id: uuid.UUID) -> list[Entity]:
    result = await db.execute(
        select(Entity)
        .where(Entity.user_id == user_id, Entity.entity_type == "task")
        .where(Entity.metadata_["promise"].as_boolean().is_(True))
        .where(func.coalesce(Entity.metadata_["done"].as_boolean(), False).is_(False))
    )
    return list(result.scalars())


async def open_waiting(db: AsyncSession, user_id: uuid.UUID) -> list[Entity]:
    """What others promised the user and has not arrived yet ("expected" tasks)."""
    result = await db.execute(
        select(Entity)
        .where(Entity.user_id == user_id, Entity.entity_type == "task")
        .where(Entity.metadata_["expected"].as_boolean().is_(True))
        .where(func.coalesce(Entity.metadata_["done"].as_boolean(), False).is_(False))
    )
    return list(result.scalars())


def _waiting_line(item: Entity) -> str:
    sender = (item.metadata_ or {}).get("expected_from")
    return f"{sender}: {item.name}" if sender else item.name


def waiting_notices(items: list[Entity], today: date, days: int) -> list[Notice]:
    """The morning after something promised to the user was due, one notice for that day
    (under the promises switch); none for those without a date."""
    due: dict[date, list[Entity]] = {}
    for item in items:
        try:
            day = date.fromisoformat(str((item.metadata_ or {}).get("due_date")))
        except ValueError:
            continue
        ask_on = day + timedelta(days=1)
        if today <= ask_on <= today + timedelta(days=days):
            due.setdefault(ask_on, []).append(item)
    notices = []
    for day, waiting in due.items():
        title = "Still waiting" if len(waiting) == 1 else f"Still waiting for {len(waiting)} things"
        notices.append(
            Notice(
                key=f"waiting:{day.isoformat()}",
                kind="promises",
                fire_at=_at_local(day, PROMISE_HOUR),
                title=title,
                body="; ".join(_waiting_line(item) for item in waiting[:3]),
                target="tasks",
            )
        )
    return notices


def _promise_line(promise: Entity) -> str:
    to = (promise.metadata_ or {}).get("promise_to")
    return f"{promise.name} (to {to})" if to else promise.name


def promise_notices(promises: list[Entity], today: date, days: int) -> list[Notice]:
    """One morning notice per day with promises due, none for those without a date."""
    due: dict[date, list[Entity]] = {}
    for promise in promises:
        try:
            day = date.fromisoformat(str((promise.metadata_ or {}).get("due_date")))
        except ValueError:
            continue
        if today <= day <= today + timedelta(days=days):
            due.setdefault(day, []).append(promise)
    notices = []
    for day, items in due.items():
        if len(items) == 1:
            title, body = "Promise for today", _promise_line(items[0])
        else:
            title = f"{len(items)} promises for today"
            body = "; ".join(_promise_line(p) for p in items[:3])
        notices.append(
            Notice(
                key=f"promises:{day.isoformat()}",
                kind="promises",
                fire_at=_at_local(day, PROMISE_HOUR),
                title=title,
                body=body,
                target="tasks",
            )
        )
    return notices


async def _calendar_events(provider, user_id: uuid.UUID, now: datetime, until: datetime):
    """Upcoming timed events, from memory for CALENDAR_CACHE_SECONDS; [] without a calendar."""
    key = str(user_id)
    cached = _calendar_cache.get(key)
    if cached and time.monotonic() - cached[0] < CALENDAR_CACHE_SECONDS:
        return cached[1]
    events: list[dict] = []
    try:
        if "googlecalendar" in await provider.connected_toolkits(key):
            result = await provider.execute(
                key,
                CALENDAR_TOOL,
                {
                    "calendarId": "primary",
                    "timeMin": now.isoformat(),
                    "timeMax": until.isoformat(),
                    "singleEvents": True,
                    "orderBy": "startTime",
                    "maxResults": 20,
                },
            )
            if result.ok and isinstance(result.data, dict):
                events = [e for e in result.data.get("items") or [] if isinstance(e, dict)]
    except ActionProviderError:
        logger.warning("Calendar unreachable for briefings", exc_info=True)
        return []
    _calendar_cache[key] = (time.monotonic(), events)
    return events


def phone_event(event: dict) -> dict:
    """An iPhone calendar event as sent by the app, shaped like a Google Calendar one."""
    start = event.get("start")
    start = start if isinstance(start, datetime) else None
    return {
        "id": f"phone:{event.get('id')}",
        "summary": event.get("title") or "",
        "description": event.get("notes"),
        "start": {"date": start.date().isoformat()}
        if event.get("all_day") and start
        else {"dateTime": start.isoformat() if start else None},
        "attendees": [
            {"displayName": a.get("name"), "email": a.get("email")}
            for a in event.get("attendees") or []
            if isinstance(a, dict)
        ],
    }


def _same_event(a: dict, b: dict) -> bool:
    """The same meeting seen twice (a Google calendar also shown on the iPhone)."""
    return (a.get("summary") or "").casefold() == (b.get("summary") or "").casefold() and (
        _event_start(a) == _event_start(b)
    )


def _event_start(event: dict) -> datetime | None:
    raw = (event.get("start") or {}).get("dateTime")  # all-day events have only a date
    try:
        return datetime.fromisoformat(raw) if raw else None
    except ValueError:
        return None


def people_in_event(event: dict, people: list[Entity]) -> list[Entity]:
    """Known people the event names (title, description, guests) or invites by email."""
    guests = [g for g in event.get("attendees") or [] if isinstance(g, dict) and not g.get("self")]
    text = " ".join(
        str(part)
        for part in (
            event.get("summary"),
            event.get("description"),
            *(g.get("displayName") for g in guests),
        )
        if part
    )
    emails = {str(g.get("email", "")).lower() for g in guests if g.get("email")}
    return [
        person
        for person in people
        if names_person(person.name, text)
        or str((person.metadata_ or {}).get("email", "")).lower() in emails - {""}
    ]


async def _what_to_know(
    db: AsyncSession,
    user_id: uuid.UUID,
    person: Entity,
    promises: list[Entity],
    now: datetime,
    waiting: Sequence[Entity] = (),
) -> list[str]:
    """Open tasks, promises both ways and a recent conversation with the person; [] when
    none. `waiting`: the open "expected" tasks (open_waiting)."""
    facts = []
    open_tasks = (
        await db.execute(
            select(func.count(Entity.id))
            .where(Entity.user_id == user_id, Entity.entity_type == "task")
            .where(func.coalesce(Entity.metadata_["done"].as_boolean(), False).is_(False))
            .where(naming(person.name))
        )
    ).scalar_one()
    promised = [
        p for p in promises
        if names_person(person.name, str((p.metadata_ or {}).get("promise_to", "")))
    ]
    if promised:
        facts.append(f"you promised: {promised[0].name}")
    theirs = [
        w for w in waiting
        if names_person(person.name, str((w.metadata_ or {}).get("expected_from", "")))
    ]
    if theirs:
        facts.append(f"they promised: {theirs[0].name}")
    # Those naming the person are among the open tasks: not counted twice
    counted = [w for w in theirs if names_person(person.name, f"{w.name} {w.content or ''}")]
    other_tasks = open_tasks - len(promised) - len(counted)
    if other_tasks > 0:
        facts.append(f"{other_tasks} open task{'s' if other_tasks > 1 else ''}")
    last = (
        await db.execute(
            select(Conversation.started_at, Conversation.title)
            .where(Conversation.user_id == user_id, in_person_conversations(person))
            .order_by(Conversation.started_at.desc())
            .limit(1)
        )
    ).first()
    if last is not None and now - last.started_at <= RECENT_CONVERSATION:
        when = last.started_at.astimezone(user_zone())
        talked = f"last talked {when:%b} {when.day}"
        facts.append(f"{talked}: {last.title}" if last.title else talked)
    return facts


async def briefing_notices(
    db: AsyncSession,
    user_id: uuid.UUID,
    provider,
    now: datetime,
    until: datetime,
    promises: list[Entity],
    phone_events: list[dict] | None = None,
    waiting: Sequence[Entity] = (),
) -> list[Notice]:
    # A copy: the Google events are cached for the next requests
    events = list(await _calendar_events(provider, user_id, now, until)) if provider else []
    for event in phone_events or []:
        if not any(_same_event(event, known) for known in events):
            events.append(event)
    if not events:
        return []
    people = list(
        (
            await db.execute(
                select(Entity).where(Entity.user_id == user_id, Entity.entity_type == "person")
            )
        ).scalars()
    )
    notices = []
    for event in events:
        start = _event_start(event)
        if start is None:
            continue
        for person in people_in_event(event, people):
            facts = await _what_to_know(db, user_id, person, promises, now, waiting)
            if not facts:
                continue
            title = event.get("summary") or "Meeting"
            notices.append(
                Notice(
                    key=f"briefing:{event.get('id') or start.isoformat()}",
                    kind="briefing",
                    fire_at=start - BRIEFING_BEFORE,
                    title=f"In 10 min: {title}",
                    body=f"{person.name}: " + " · ".join(facts),
                    target=f"person:{person.id}",
                )
            )
            break  # one briefing per meeting, about the first person with something
    return notices


# Today's "coming up" card: an event this soon, with what was said last time
COMING_UP_WITHIN = timedelta(hours=1)


@dataclass(frozen=True)
class ComingUp:
    title: str
    start: datetime
    # "Last time: <conversation title>", with its people or about its title; None without
    recap: str | None


async def _last_talk(db: AsyncSession, user_id: uuid.UUID, condition) -> str | None:
    title = (
        await db.execute(
            select(Conversation.title)
            .where(Conversation.user_id == user_id, Conversation.title.isnot(None), condition)
            .order_by(Conversation.started_at.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    return f"Last time: {title}" if title else None


async def coming_up(
    db: AsyncSession, user_id: uuid.UUID, events: list[dict], now: datetime
) -> ComingUp | None:
    """The first event starting in the next hour (phone_event shape), with a recap from the
    last conversation with someone it names, else about its title. None without one."""
    soon = sorted(
        (
            (start, event)
            for event in events
            if (start := _event_start(event)) is not None
            and now <= start <= now + COMING_UP_WITHIN
        ),
        key=lambda pair: pair[0],
    )
    if not soon:
        return None
    start, event = soon[0]
    title = (event.get("summary") or "").strip() or "Meeting"
    people = list(
        (
            await db.execute(
                select(Entity).where(Entity.user_id == user_id, Entity.entity_type == "person")
            )
        ).scalars()
    )
    recap = None
    for person in people_in_event(event, people):
        recap = await _last_talk(db, user_id, in_person_conversations(person))
        if recap:
            break
    if recap is None and len(title) >= 3:
        recap = await _last_talk(db, user_id, Conversation.title.icontains(title, autoescape=True))
    return ComingUp(title=title, start=start, recap=recap)


async def evening_notice(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> list[Notice]:
    today = now.astimezone(user_zone()).date()
    start, end = local_day_bounds(today)
    conversations = (
        await db.execute(
            select(func.count(Conversation.id)).where(
                Conversation.user_id == user_id,
                Conversation.started_at >= start,
                Conversation.started_at < end,
            )
        )
    ).scalar_one()
    if not conversations:
        return []
    tasks = (
        await db.execute(
            select(func.count(Entity.id)).where(
                Entity.user_id == user_id,
                Entity.entity_type == "task",
                Entity.created_at >= start,
                Entity.created_at < end,
            )
        )
    ).scalar_one()
    body = f"{conversations} conversation{'s' if conversations > 1 else ''}"
    if tasks:
        body += f", {tasks} new task{'s' if tasks > 1 else ''}"
    return [
        Notice(
            key=f"evening:{today.isoformat()}",
            kind="evening",
            fire_at=_at_local(today, EVENING_HOUR),
            title="Your day with Echo",
            body=body,
            target="today",
        )
    ]


async def upcoming_notices(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    now: datetime | None = None,
    hours: int = 36,
    briefings: bool = True,
    promises: bool = True,
    evening: bool = False,
    provider=None,
    phone_events: list[dict] | None = None,
    taken: dict[date, int] | None = None,
) -> list[Notice]:
    """What to schedule for the next `hours`, already filtered by the rules above.

    `phone_events`: the iPhone calendar's next events, already shaped by `phone_event`;
    `taken`: per day, the notices already given (services/notice_ledger.py).
    """
    now = now or datetime.now(timezone.utc)
    until = now + timedelta(hours=hours)
    today = now.astimezone(user_zone()).date()
    open_ones = await open_promises(db, user_id)
    waiting = await open_waiting(db, user_id) if promises or briefings else []
    notices: list[Notice] = []
    if promises:
        notices += promise_notices(open_ones, today, days=hours // 24 + 1)
        notices += waiting_notices(waiting, today, days=hours // 24 + 1)
    if briefings and (provider is not None or phone_events):
        notices += await briefing_notices(
            db, user_id, provider, now, until, open_ones, phone_events, waiting
        )
    if evening:
        notices += await evening_notice(db, user_id, now)
    return select_notices(notices, now, until, taken)
