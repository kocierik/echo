"""What the phone was given to show, per user and day, kept in Redis (no table).

The scheduled notices (services/notifications.py) are recomputed on every wake and live on
the phone; the "who is in front of you" brief (services/person_brief.py) is sent at once.
Both count in the same MAX_PER_DAY, so each is written down here:

- `/notifications/upcoming` replaces the day's entries still to fire with what it hands
  out (those already fired stay), and remembers the briefings switch it was sent;
- a brief sent at once is added as it goes.

A day's entries (`DAY_KEY`, a hash: notice key → kind, fire time, target) say how many the
day has had or will have, and when a meeting briefing about someone fires.
"""

import json
import uuid
from datetime import date, datetime, timedelta

from app.core.timezone import user_zone
from app.services.notifications import Notice

DAY_KEY = "notify:day:{user_id}:{day}"
DAY_TTL_S = 3 * 24 * 3600
BRIEFINGS_OFF_KEY = "notify:briefings-off:{user_id}"


def _day(moment: datetime) -> date:
    return moment.astimezone(user_zone()).date()


def _days(start: datetime, end: datetime) -> list[date]:
    first, last = _day(start), _day(end)
    return [first + timedelta(days=i) for i in range((last - first).days + 1)]


def _key(user_id: uuid.UUID | str, day: date) -> str:
    return DAY_KEY.format(user_id=user_id, day=day.isoformat())


def _text(value) -> str:
    return value.decode() if isinstance(value, bytes) else str(value)


async def _entries(redis, user_id: uuid.UUID | str, day: date) -> dict[str, dict]:
    """The day's entries by notice key; unreadable ones left out."""
    entries = {}
    for field, raw in (await redis.hgetall(_key(user_id, day))).items():
        try:
            entry = json.loads(_text(raw))
            entry["fire_at"] = datetime.fromisoformat(entry["fire_at"])
        except (ValueError, KeyError, TypeError):
            continue
        entries[_text(field)] = entry
    return entries


async def _add(redis, user_id, key: str, kind: str, fire_at: datetime, target: str) -> None:
    day_key = _key(user_id, _day(fire_at))
    entry = {"kind": kind, "fire_at": fire_at.isoformat(), "target": target}
    await redis.hset(day_key, key, json.dumps(entry))
    await redis.expire(day_key, DAY_TTL_S)


async def record_scheduled(
    redis, user_id: uuid.UUID, notices: list[Notice], now: datetime, until: datetime
) -> None:
    """What the phone schedules now replaces what it had for (now, until]."""
    for day in _days(now, until):
        stale = [
            key
            for key, entry in (await _entries(redis, user_id, day)).items()
            if now < entry["fire_at"] <= until
        ]
        if stale:
            await redis.hdel(_key(user_id, day), *stale)
    for notice in notices:
        await _add(redis, user_id, notice.key, notice.kind, notice.fire_at, notice.target)


async def record_sent(
    redis, user_id: uuid.UUID, key: str, kind: str, target: str, now: datetime
) -> None:
    """A notice shown at once (not scheduled)."""
    await _add(redis, user_id, key, kind, now, target)


async def given_per_day(
    redis, user_id: uuid.UUID, now: datetime, until: datetime
) -> dict[date, int]:
    """Per day from now to until, the notices already given (fired or sent)."""
    given = {}
    for day in _days(now, until):
        count = sum(
            entry["fire_at"] <= now for entry in (await _entries(redis, user_id, day)).values()
        )
        if count:
            given[day] = count
    return given


async def count_on(redis, user_id: uuid.UUID, day: date) -> int:
    """The day's notices: fired, sent at once or still to fire."""
    return len(await _entries(redis, user_id, day))


async def briefing_near(
    redis, user_id: uuid.UUID, target: str, now: datetime, within: timedelta
) -> bool:
    """A meeting briefing about `target` ("person:<id>") fires within `within` of now."""
    for day in _days(now - within, now + within):
        for entry in (await _entries(redis, user_id, day)).values():
            if (
                entry.get("kind") == "briefing"
                and entry.get("target") == target
                and abs(entry["fire_at"] - now) <= within
            ):
                return True
    return False


async def set_briefings(redis, user_id: uuid.UUID, on: bool) -> None:
    """The briefings switch, as the app last sent it."""
    key = BRIEFINGS_OFF_KEY.format(user_id=user_id)
    if on:
        await redis.delete(key)
    else:
        await redis.set(key, "1")


async def briefings_on(redis, user_id: uuid.UUID) -> bool:
    return await redis.get(BRIEFINGS_OFF_KEY.format(user_id=user_id)) is None
