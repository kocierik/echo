"""The iPhone's Health app in Echo's answers (Profile → Health).

Echo's app cannot read HealthKit when signed with a free Apple ID (SideStore), so Apple's
Shortcuts sends the day instead: an automation each evening reads sleep, steps, distance,
exercise and workouts and posts them with a key that can only do that (scope "health").
What Shortcuts sends is loose (numbers as the phone's locale writes them, sleep in hours,
minutes or seconds), so it is read leniently here; the last two weeks go into every
answer's prompt (services/personal.py), so "how did I sleep" and the charts use them.
"""

import re
import uuid
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import to_user_local_date
from app.models.health_day import HealthDay

CONTEXT_DAYS = 14
MAX_WORKOUTS = 300

_NUMBER = re.compile(r"-?\d[\d.,]*")
_CLOCK = re.compile(r"^\s*(\d{1,2})[:.h]\s*(\d{1,2})\s*(?:m|min)?\s*$", re.IGNORECASE)
_HOURS_MINUTES = re.compile(r"(\d+(?:[.,]\d+)?)\s*h(?:ours?|ore)?\s*(?:(\d+)\s*m)?", re.IGNORECASE)


def _number(value, *, integer: bool) -> float | None:
    """A number as a phone may write it: 8421, "8.421" (Italian thousands), "6,8"."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int | float):
        return float(value)
    found = _NUMBER.search(str(value).replace(" ", "").replace(" ", ""))
    if not found:
        return None
    text = found.group().rstrip(".,")
    if "," in text and "." in text:
        # Both: the last one is the decimal mark
        decimal = "," if text.rfind(",") > text.rfind(".") else "."
        text = text.replace("." if decimal == "," else ",", "").replace(",", ".")
    elif "," in text or "." in text:
        mark = "," if "," in text else "."
        parts = text.split(mark)
        thousands = all(len(p) == 3 for p in parts[1:]) and (integer or len(parts) > 2)
        text = "".join(parts) if thousands else text.replace(",", ".")
    try:
        return float(text)
    except ValueError:
        return None


def sleep_minutes(value) -> int | None:
    """Sleep as Shortcuts may send it: hours (6.8), minutes (410), seconds (24600),
    "6:50" or "6 h 50 m"."""
    if isinstance(value, str):
        if clock := _CLOCK.match(value):
            return int(clock[1]) * 60 + int(clock[2])
        if hm := _HOURS_MINUTES.search(value):
            hours = _number(hm[1], integer=False) or 0
            return round(hours * 60 + int(hm[2] or 0))
    number = _number(value, integer=False)
    if number is None or number < 0:
        return None
    minutes = number * 60 if number <= 24 else number if number <= 1440 else number / 60
    return round(min(minutes, 24 * 60))


def distance_km(value) -> float | None:
    """Kilometres, or metres when it cannot be kilometres walked in a day."""
    number = _number(value, integer=False)
    if number is None or number < 0:
        return None
    return round(number / 1000 if number > 200 else number, 2)


def _whole(value, most: int) -> int | None:
    number = _number(value, integer=True)
    if number is None or number < 0:
        return None
    return round(min(number, most))


def today() -> date:
    """The user's today."""
    return to_user_local_date(datetime.now(timezone.utc))


def parse_day(value, default: date) -> date:
    """"2026-11-05", "05/11/2026", or `default` (the user's today)."""
    text = str(value or "").strip()
    for pattern in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%d.%m.%Y"):
        try:
            return datetime.strptime(text[:10], pattern).date()
        except ValueError:
            continue
    return default


def read_day(body: dict, default_day: date) -> dict:
    """What a Shortcuts post says about one day, as columns (None: not sent)."""
    workouts = body.get("workouts")
    if isinstance(workouts, list):
        workouts = ", ".join(str(w) for w in workouts if str(w).strip())
    workouts = " ".join(str(workouts or "").split())[:MAX_WORKOUTS] or None
    return {
        "day": parse_day(body.get("date") or body.get("day"), default_day),
        "sleep_minutes": sleep_minutes(body.get("sleep")),
        "steps": _whole(body.get("steps"), 200_000),
        "distance_km": distance_km(body.get("distance")),
        "active_kcal": _whole(body.get("active_kcal") or body.get("energy"), 20_000),
        "exercise_minutes": _whole(body.get("exercise_minutes") or body.get("exercise"), 1440),
        "resting_hr": _whole(body.get("resting_hr"), 250),
        "workouts": workouts,
    }


async def save_day(db: AsyncSession, user_id: uuid.UUID, values: dict, source: str) -> None:
    """The day's values; one sent again replaces only what it carries."""
    sent = {k: v for k, v in values.items() if v is not None and k != "day"}
    statement = insert(HealthDay).values(
        user_id=user_id, day=values["day"], source=source,
        updated_at=datetime.now(timezone.utc), **sent,
    )
    statement = statement.on_conflict_do_update(
        index_elements=[HealthDay.user_id, HealthDay.day],
        set_={**sent, "source": source, "updated_at": statement.excluded.updated_at},
    )
    await db.execute(statement)


async def recent_days(db: AsyncSession, user_id: uuid.UUID, days: int = CONTEXT_DAYS):
    """The last `days` days that have something, newest first."""
    since = today() - timedelta(days=days - 1)
    return list(await db.scalars(
        select(HealthDay)
        .where(HealthDay.user_id == user_id, HealthDay.day >= since)
        .order_by(HealthDay.day.desc())
    ))


async def forget(db: AsyncSession, user_id: uuid.UUID) -> int:
    result = await db.execute(delete(HealthDay).where(HealthDay.user_id == user_id))
    return result.rowcount or 0


def _duration(minutes: int) -> str:
    return f"{minutes // 60} h {minutes % 60:02d} min"


def describe(day: HealthDay) -> str:
    parts = []
    if day.sleep_minutes is not None:
        parts.append(f"slept {_duration(day.sleep_minutes)}")
    if day.steps is not None:
        parts.append(f"{day.steps} steps")
    if day.distance_km is not None:
        parts.append(f"{day.distance_km:g} km walked or run")
    if day.exercise_minutes is not None:
        parts.append(f"{day.exercise_minutes} min of exercise")
    if day.active_kcal is not None:
        parts.append(f"{day.active_kcal} active kcal")
    if day.resting_hr is not None:
        parts.append(f"resting heart rate {day.resting_hr}")
    if day.workouts:
        parts.append(f"workouts: {day.workouts}")
    return f"- {day.day.strftime('%a')} {day.day.isoformat()}: {', '.join(parts) or 'nothing'}"


async def health_context(db: AsyncSession, user_id: uuid.UUID) -> str:
    """The last two weeks of Health, for the prompt; "" without any."""
    days = await recent_days(db, user_id)
    if not days:
        return ""
    lines = [describe(d) for d in days]
    slept = [d.sleep_minutes for d in days if d.sleep_minutes is not None]
    walked = [d.steps for d in days if d.steps is not None]
    averages = []
    if slept:
        averages.append(f"sleep {_duration(round(sum(slept) / len(slept)))}")
    if walked:
        averages.append(f"{round(sum(walked) / len(walked))} steps")
    return (
        "From the user's iPhone Health app (sent each day by Apple's Shortcuts; sleep is "
        "the night that ended that morning). Use it for questions about sleep, steps, "
        "exercise and how they feel; never guess a day that is not listed:\n"
        + "\n".join(lines)
        + (f"\nAverages of these days: {', '.join(averages)}." if averages else "")
    )
