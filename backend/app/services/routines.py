"""Routines: what Echo does on its own at a time the user asked for.

A schedule is structured (the agent turns "ogni mattina alle 7" into it):
{"kind": "daily" | "weekdays" | "weekly" | "monthly", "time": "HH:MM",
 "days": [1-7] (weekly, ISO: 1 = Monday), "day_of_month": 1-28 (monthly)}.
Times are wall times in the routine's time zone and stored as UTC instants, so a 07:00
routine stays at 07:00 across daylight saving. Never more often than once a day.
"""

import re
import uuid
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.routine import Routine
from app.services.plans import user_plan
from app.services.routine_results import MODES

KINDS = ("daily", "weekdays", "weekly", "monthly", "after_conversation")
# "after_conversation": run on each conversation once it is closed and summarized
# (workers/routines.run_conversation_routines), never by the clock
AFTER_CONVERSATION = "after_conversation"
NEVER = datetime(9999, 1, 1, tzinfo=timezone.utc)

_TIME = re.compile(r"^([01]?\d|2[0-3]):([0-5]\d)$")
_DAY_NAMES = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def validate_schedule(schedule) -> dict:
    """The schedule, normalized; ValueError with a message the model can relay."""
    if not isinstance(schedule, dict):
        raise ValueError("The schedule must be an object with a kind and a time.")
    kind = schedule.get("kind")
    if kind not in KINDS:
        raise ValueError(
            "The schedule kind must be daily, weekdays, weekly, monthly or after_conversation."
        )
    if kind == AFTER_CONVERSATION:
        return {"kind": kind}
    match = _TIME.match(str(schedule.get("time", "")).strip())
    if not match:
        raise ValueError("The time must be HH:MM, 24-hour.")
    normalized: dict = {"kind": kind, "time": f"{int(match[1]):02d}:{match[2]}"}
    if kind == "weekly":
        days = schedule.get("days")
        if (
            not isinstance(days, list)
            or not days
            or not all(isinstance(d, int) and 1 <= d <= 7 for d in days)
        ):
            raise ValueError("A weekly routine needs its days, 1 (Monday) to 7 (Sunday).")
        normalized["days"] = sorted(set(days))
    if kind == "monthly":
        day = schedule.get("day_of_month")
        if not isinstance(day, int) or not 1 <= day <= 28:
            raise ValueError("A monthly routine needs its day of the month, 1 to 28.")
        normalized["day_of_month"] = day
    return normalized


def validate_timezone(name: str) -> str:
    try:
        ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        raise ValueError(f"Unknown time zone: {name}") from None
    return name


def _runs_on(schedule: dict, day: date) -> bool:
    kind = schedule["kind"]
    if kind == "daily":
        return True
    if kind == "weekdays":
        return day.isoweekday() <= 5
    if kind == "weekly":
        return day.isoweekday() in schedule["days"]
    return day.day == schedule["day_of_month"]


def next_run(schedule: dict, tz: str, after: datetime) -> datetime:
    """The first run strictly after `after` (UTC); never for one run by conversations."""
    if schedule["kind"] == AFTER_CONVERSATION:
        return NEVER
    zone = ZoneInfo(tz)
    hour, minute = (int(part) for part in schedule["time"].split(":"))
    start = after.astimezone(zone).date()
    # A monthly day is at most a month and a bit away
    for offset in range(0, 62):
        day = start + timedelta(days=offset)
        if not _runs_on(schedule, day):
            continue
        # A wall time the clocks skip (spring forward) is read with the earlier offset:
        # it still runs that morning, an hour later on the clock
        run = datetime.combine(day, time(hour, minute), tzinfo=zone).astimezone(timezone.utc)
        if run > after:
            return run
    raise ValueError("No run within two months")  # pragma: no cover - validated schedules


def _ordinal(n: int) -> str:
    suffix = "th" if 11 <= n % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def describe_schedule(schedule: dict) -> str:
    """The schedule in words, as the app shows it (English)."""
    if schedule["kind"] == AFTER_CONVERSATION:
        return "After each conversation"
    at = schedule["time"]
    kind = schedule["kind"]
    if kind == "daily":
        return f"Every day at {at}"
    if kind == "weekdays":
        return f"Weekdays at {at}"
    if kind == "weekly":
        names = [_DAY_NAMES[d - 1] for d in schedule["days"]]
        days = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
        return f"Every {days} at {at}"
    return f"On the {_ordinal(schedule['day_of_month'])} of every month at {at}"


class RoutineError(ValueError):
    """A routine that cannot be added: the reason, said to the user."""


async def add_routine(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    instruction: str,
    schedule: dict,
    mode: str = "always",
    source: str = "chat",
    assistant_id: uuid.UUID | None = None,
    catalog_key: str | None = None,
) -> Routine:
    """A new routine (no commit), checked: its schedule, its mode, the plan's limit.
    Asked for in words (the agent's tool) or added from the catalog."""
    instruction = instruction.strip()
    if not instruction:
        raise RoutineError("instruction is required")
    schedule = validate_schedule(schedule)
    if mode not in MODES:
        raise RoutineError("mode must be always, only_if or only_new")
    count = await db.scalar(
        select(func.count()).select_from(Routine).where(Routine.user_id == user_id)
    )
    # As many as the plan has (services/plans.py); a lowered plan keeps the ones made
    limit = (await user_plan(db, user_id)).routines
    if count >= limit:
        raise RoutineError(
            f"At most {limit} routines on your plan. Delete one first (Profile → Routines)."
        )
    tz = settings.user_timezone
    routine = Routine(
        id=uuid.uuid4(),
        user_id=user_id,
        instruction=instruction,
        schedule=schedule,
        timezone=tz,
        active=True,
        next_run_at=next_run(schedule, tz, datetime.now(timezone.utc)),
        source=source,
        mode=mode,
        assistant_id=assistant_id,
        catalog_key=catalog_key,
    )
    db.add(routine)
    await db.flush()
    return routine

