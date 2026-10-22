"""Routines: what Echo does on its own at a time the user asked for.

A schedule is structured (the agent turns "ogni mattina alle 7" into it):
{"kind": "daily" | "weekdays" | "weekly" | "monthly", "time": "HH:MM",
 "days": [1-7] (weekly, ISO: 1 = Monday), "day_of_month": 1-28 (monthly)}.
Times are wall times in the routine's time zone and stored as UTC instants, so a 07:00
routine stays at 07:00 across daylight saving. Never more often than once a day.
"""

import re
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# At most this many routines per user
MAX_ROUTINES = 10

KINDS = ("daily", "weekdays", "weekly", "monthly")

_TIME = re.compile(r"^([01]?\d|2[0-3]):([0-5]\d)$")
_DAY_NAMES = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def validate_schedule(schedule) -> dict:
    """The schedule, normalized; ValueError with a message the model can relay."""
    if not isinstance(schedule, dict):
        raise ValueError("The schedule must be an object with a kind and a time.")
    kind = schedule.get("kind")
    if kind not in KINDS:
        raise ValueError("The schedule kind must be daily, weekdays, weekly or monthly.")
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
    """The first run strictly after `after` (UTC)."""
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
