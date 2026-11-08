"""Places visited: the stays the phone noticed, for the users who turned it on.

The phone works out the stays (iOS: the system's visit detection; Android: low-power
positions made into stays on the phone) and sends each one when it starts and again when
it ends, under the same `key`. Here they are kept as visits when they are one: 10 minutes
or more in one place, a fix good enough to say where (a short or vague stay is not a
visit). Kept 90 days, then deleted (workers/places.py); the user deletes one, a day or
all of them from Profile → Places visited.

A conversation's place is worked out when it is read, from the times: the visit it
mostly happened in (at least half of it). Nothing is written on the conversation.

Used by the places API, the conversations API and memory retrieval. Nothing here calls a
model; nothing commits except the cleanup.
"""

import logging
import re
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from sqlalchemy import delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import local_day_bounds, user_zone
from app.models.place_visit import PlaceVisit
from app.services.phone_location import valid_place

logger = logging.getLogger(__name__)

# A stay counts as a visit from this long in one place
MIN_VISIT = timedelta(minutes=10)
KEEP_DAYS = 90
# A fix vaguer than this does not say where the user was
MAX_ACCURACY_M = 300.0
# The phone's clock may run a little ahead of the server's
CLOCK_SLACK = timedelta(minutes=5)
MAX_TEXT = 300


@dataclass
class VisitIn:
    """A stay as the phone sends it; `left_at` None while the user is still there."""

    key: str
    arrived_at: datetime
    left_at: datetime | None
    latitude: float
    longitude: float
    accuracy_m: float | None = None
    name: str | None = None
    address: str | None = None


def _text(value: str | None) -> str | None:
    if not isinstance(value, str):
        return None
    return " ".join(value.split())[:MAX_TEXT] or None


def _acceptable(visit: VisitIn, now: datetime) -> bool:
    """Whether the stay can be kept at all: where, when, and not too vague or old."""
    place = valid_place({"latitude": visit.latitude, "longitude": visit.longitude})
    if place is None or not visit.key.strip():
        return False
    if visit.accuracy_m is not None and visit.accuracy_m > MAX_ACCURACY_M:
        return False
    if visit.arrived_at > now + CLOCK_SLACK:
        return False
    if visit.arrived_at < now - timedelta(days=KEEP_DAYS):
        return False
    return visit.left_at is None or visit.left_at >= visit.arrived_at


async def record_visits(
    db: AsyncSession,
    user_id: uuid.UUID,
    visits: list[VisitIn],
    *,
    source: str,
    now: datetime,
) -> tuple[int, int]:
    """Keep the phone's stays, one visit per key: (kept, dropped).

    A stay that ended under 10 minutes is no visit: dropped, and the one sent when it
    started is deleted."""
    kept = dropped = 0
    for visit in visits:
        key = visit.key.strip()[:80]
        existing = await db.scalar(
            select(PlaceVisit).where(PlaceVisit.user_id == user_id, PlaceVisit.key == key)
        )
        too_short = visit.left_at is not None and visit.left_at - visit.arrived_at < MIN_VISIT
        if not _acceptable(visit, now) or too_short:
            dropped += 1
            if existing is not None and too_short:
                await db.delete(existing)
            continue
        if existing is None:
            existing = PlaceVisit(id=uuid.uuid4(), user_id=user_id, key=key, source=source)
            db.add(existing)
        existing.arrived_at = visit.arrived_at
        existing.left_at = visit.left_at
        existing.latitude = float(visit.latitude)
        existing.longitude = float(visit.longitude)
        existing.accuracy_m = visit.accuracy_m
        # A name or an address the phone found once is not lost when a later send has none
        existing.name = _text(visit.name) or existing.name
        existing.address = _text(visit.address) or existing.address
        existing.updated_at = now
        kept += 1
    await db.flush()
    await _close_left_stays(db, user_id)
    return kept, dropped


async def _close_left_stays(db: AsyncSession, user_id: uuid.UUID) -> None:
    """iOS often sends the arrival and never the departure: a stay with a later arrival
    ended there, else it reads as going on until now and claims what happened since."""
    stays = list(await db.scalars(
        select(PlaceVisit).where(PlaceVisit.user_id == user_id).order_by(PlaceVisit.arrived_at)
    ))
    for stay, after in zip(stays, stays[1:]):
        if stay.left_at is None:
            stay.left_at = after.arrived_at
    await db.flush()


def _end(visit: PlaceVisit, now: datetime) -> datetime:
    return visit.left_at or now


def counts(visit: PlaceVisit, now: datetime) -> bool:
    """A visit already: ended after 10 minutes or more, or going on for that long."""
    return _end(visit, now) - visit.arrived_at >= MIN_VISIT


async def visits_between(
    db: AsyncSession,
    user_id: uuid.UUID,
    start: datetime | None,
    end: datetime | None,
    *,
    now: datetime,
    limit: int | None = None,
) -> list[PlaceVisit]:
    """The visits overlapping [start, end) (open ends: everything), oldest first."""
    query = select(PlaceVisit).where(PlaceVisit.user_id == user_id)
    if end is not None:
        query = query.where(PlaceVisit.arrived_at < end)
    if start is not None:
        query = query.where(or_(PlaceVisit.left_at.is_(None), PlaceVisit.left_at > start))
    found = [
        v for v in await db.scalars(query.order_by(PlaceVisit.arrived_at)) if counts(v, now)
    ]
    return found[-limit:] if limit else found


def _overlap(start: datetime, end: datetime, visit: PlaceVisit, now: datetime) -> timedelta:
    return min(end, _end(visit, now)) - max(start, visit.arrived_at)


async def places_of(
    db: AsyncSession,
    user_id: uuid.UUID,
    spans: list[tuple[uuid.UUID, datetime, datetime | None]],
    *,
    now: datetime,
) -> dict[uuid.UUID, PlaceVisit]:
    """Per conversation (id, started, ended): the visit it mostly happened in, kept when
    at least half of it was there. One that lasted under a minute: where it started."""
    if not spans:
        return {}
    first = min(start for _, start, _ in spans)
    last = max(end or start for _, start, end in spans)
    visits = await visits_between(
        db, user_id, first - timedelta(seconds=1), last + timedelta(seconds=1), now=now
    )
    found: dict[uuid.UUID, PlaceVisit] = {}
    if not visits:
        return found
    for conversation_id, start, end in spans:
        end = end or start
        if end - start < timedelta(minutes=1):
            inside = [v for v in visits if v.arrived_at <= start <= _end(v, now)]
            if inside:
                found[conversation_id] = inside[-1]
            continue
        best = max(visits, key=lambda v: _overlap(start, end, v, now))
        if _overlap(start, end, best, now) * 2 >= end - start:
            found[conversation_id] = best
    return found


def label(visit: PlaceVisit) -> str | None:
    """What the place is called: its name, else its address."""
    return visit.name or visit.address


def place_out(visit: PlaceVisit) -> dict:
    """A conversation's place for the app."""
    return {"visit_id": visit.id, "name": visit.name, "address": visit.address}


async def delete_visit(db: AsyncSession, user_id: uuid.UUID, visit_id: uuid.UUID) -> bool:
    """Delete one of the user's visits; False when there is no such visit of theirs."""
    visit = await db.get(PlaceVisit, visit_id)
    if visit is None or visit.user_id != user_id:
        return False
    await db.delete(visit)
    await db.flush()
    return True


async def delete_day(db: AsyncSession, user_id: uuid.UUID, day: date) -> int:
    """Delete the visits that started on `day` (the user's time zone)."""
    start, end = local_day_bounds(day)
    result = await db.execute(
        delete(PlaceVisit).where(
            PlaceVisit.user_id == user_id,
            PlaceVisit.arrived_at >= start,
            PlaceVisit.arrived_at < end,
        )
    )
    return result.rowcount or 0


async def delete_all(db: AsyncSession, user_id: uuid.UUID) -> int:
    result = await db.execute(delete(PlaceVisit).where(PlaceVisit.user_id == user_id))
    return result.rowcount or 0


async def expire_visits(db: AsyncSession, now: datetime) -> int:
    """Delete the visits that started more than 90 days ago. Commits."""
    result = await db.execute(
        delete(PlaceVisit).where(PlaceVisit.arrived_at < now - timedelta(days=KEEP_DAYS))
    )
    await db.commit()
    return result.rowcount or 0


# --- For memory answers ---

# A question about where the user was or went (Italian and English)
_PLACE_QUESTION = re.compile(
    r"\b(dove|dov'|where|posto|posti|luogo|luoghi|places?|ristorante|restaurant|"
    r"stat[oaie]|andat[oaie]|venut[oaie]|went|been|go(ne)?|visit\w*|"
    r"ultima volta|last time)\b",
    re.IGNORECASE,
)
# Words of a question that say nothing about which place
_STOP_WORDS = {
    "dove", "quando", "quante", "quanti", "volte", "sono", "siamo", "stato", "stata",
    "stati", "state", "andato", "andata", "andati", "andate", "ultima", "volta", "with",
    "where", "when", "often", "went", "been", "last", "time", "have", "what", "which",
    "questa", "questo", "settimana", "week", "ieri", "oggi", "yesterday", "today", "sera",
    "evening", "mattina", "morning", "from", "that", "this", "abbiamo", "cenato",
    "pranzato", "dinner", "lunch", "cena", "pranzo", "posto", "luogo", "place", "places",
}
CONTEXT_VISITS = 30
CONTEXT_PLACES = 25


def _local(moment: datetime) -> datetime:
    return moment.astimezone(user_zone())


def _span(visit: PlaceVisit) -> str:
    arrived = _local(visit.arrived_at)
    day = arrived.strftime("%A %d/%m/%Y")
    if visit.left_at is None:
        return f"{day} {arrived:%H:%M}–now"
    left = _local(visit.left_at)
    if left.date() != arrived.date():
        return f"{day} {arrived:%H:%M}–{left.strftime('%A %d/%m/%Y %H:%M')}"
    return f"{day} {arrived:%H:%M}–{left:%H:%M}"


def _where(visit: PlaceVisit) -> str:
    if visit.name and visit.address:
        return f"{visit.name} ({visit.address})"
    return label(visit) or f"{visit.latitude:.4f}, {visit.longitude:.4f}"


def visit_line(visit: PlaceVisit) -> str:
    """"- Saturday 17/10/2026 19:55–23:10: Pizzeria Da Gino (Via Garibaldi 5, Milano)"."""
    return f"- {_span(visit)}: {_where(visit)}"


def _place_words(question: str) -> list[str]:
    words = []
    for raw in re.split(r"[\s'’]+", question.lower()):
        word = raw.strip("?.,!:;\"()«»")
        if len(word) >= 4 and word not in _STOP_WORDS and word not in words:
            words.append(word)
    return words


def _named(visit: PlaceVisit, words: list[str]) -> bool:
    text = f"{visit.name or ''} {visit.address or ''}".lower()
    return any(word in text for word in words)


async def places_context(
    db: AsyncSession,
    user_id: uuid.UUID,
    question: str,
    date_from: datetime | None,
    date_to: datetime | None,
    *,
    now: datetime,
) -> str:
    """The "Places visited" lines for a memory answer ("" when none fit).

    With a period: its visits, in time order. Without one, for a question about where the
    user was or one naming a place: the places of the last 90 days, the named ones and
    then the latest first, each with its last visit and how many."""
    if date_from is not None or date_to is not None:
        visits = await visits_between(
            db, user_id, date_from, date_to, now=now, limit=CONTEXT_VISITS
        )
        return "\n".join(visit_line(v) for v in visits)
    visits = await visits_between(db, user_id, now - timedelta(days=KEEP_DAYS), None, now=now)
    if not visits:
        return ""
    words = _place_words(question)
    named = {v.id for v in visits if words and _named(v, words)}
    if not named and not _PLACE_QUESTION.search(question):
        return ""
    by_place: dict[str, list[PlaceVisit]] = {}
    for visit in reversed(visits):  # newest first
        by_place.setdefault(_where(visit).lower(), []).append(visit)
    groups = sorted(
        by_place.values(),
        key=lambda group: (
            not any(v.id in named for v in group),
            -group[0].arrived_at.timestamp(),
        ),
    )
    lines = []
    for group in groups[:CONTEXT_PLACES]:
        count = "1 visit" if len(group) == 1 else f"{len(group)} visits"
        lines.append(
            f"- {_where(group[0])}: last on {_span(group[0])}; {count} in the last "
            f"{KEEP_DAYS} days"
        )
    return "\n".join(lines)
