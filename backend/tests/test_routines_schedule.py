"""When a routine runs next: the wall time in its time zone, kept across daylight saving."""

from datetime import datetime, timezone

import pytest

from app.services.routines import describe_schedule, next_run, validate_schedule

ROME = "Europe/Rome"


def utc(*args) -> datetime:
    return datetime(*args, tzinfo=timezone.utc)


def test_daily_at_seven_is_the_next_seven_local():
    daily = {"kind": "daily", "time": "07:00"}

    # 21 Oct 2026, Rome is UTC+2: 07:00 local = 05:00 UTC
    assert next_run(daily, ROME, utc(2026, 10, 21, 4, 0)) == utc(2026, 10, 21, 5, 0)
    # Already past today: tomorrow
    assert next_run(daily, ROME, utc(2026, 10, 21, 5, 0)) == utc(2026, 10, 22, 5, 0)


def test_daylight_saving_keeps_seven_oclock():
    daily = {"kind": "daily", "time": "07:00"}

    # Clocks go back on Sunday 25 Oct 2026: from then 07:00 local = 06:00 UTC
    assert next_run(daily, ROME, utc(2026, 10, 24, 5, 0)) == utc(2026, 10, 25, 6, 0)
    # And forward on 28 Mar 2027
    assert next_run(daily, ROME, utc(2027, 3, 27, 6, 0)) == utc(2027, 3, 28, 5, 0)


def test_a_time_the_clocks_skip_still_runs_that_day():
    # 02:30 does not exist in Rome on 28 Mar 2027: it runs once, that morning
    run = next_run({"kind": "daily", "time": "02:30"}, ROME, utc(2027, 3, 27, 12, 0))
    assert run.date() == utc(2027, 3, 28).date()


def test_weekdays_skip_the_weekend():
    weekdays = {"kind": "weekdays", "time": "08:30"}

    # Friday 23 Oct after the run: next is Monday 26 (UTC+1 by then)
    assert next_run(weekdays, ROME, utc(2026, 10, 23, 7, 0)) == utc(2026, 10, 26, 7, 30)


def test_weekly_on_the_given_days():
    weekly = {"kind": "weekly", "time": "09:00", "days": [1, 4]}

    # Wednesday 21 Oct: next is Thursday 22
    assert next_run(weekly, ROME, utc(2026, 10, 21, 12, 0)) == utc(2026, 10, 22, 7, 0)
    # Thursday after the run: Monday 26
    assert next_run(weekly, ROME, utc(2026, 10, 22, 7, 0)) == utc(2026, 10, 26, 8, 0)


def test_monthly_on_a_day():
    monthly = {"kind": "monthly", "time": "08:00", "day_of_month": 1}

    assert next_run(monthly, ROME, utc(2026, 10, 21, 12, 0)) == utc(2026, 11, 1, 7, 0)


@pytest.mark.parametrize(
    "schedule",
    [
        {"kind": "hourly", "time": "07:00"},
        {"kind": "daily", "time": "25:00"},
        {"kind": "daily", "time": "7"},
        {"kind": "daily"},
        {"kind": "weekly", "time": "09:00", "days": []},
        {"kind": "weekly", "time": "09:00", "days": [0]},
        {"kind": "monthly", "time": "09:00", "day_of_month": 31},
        "every day",
    ],
)
def test_bad_schedules_are_refused(schedule):
    with pytest.raises(ValueError):
        validate_schedule(schedule)


def test_a_good_schedule_is_normalized():
    assert validate_schedule({"kind": "weekly", "time": "9:05", "days": [4, 1, 4]}) == {
        "kind": "weekly", "time": "09:05", "days": [1, 4],
    }
    assert validate_schedule({"kind": "daily", "time": "07:00", "days": [1]}) == {
        "kind": "daily", "time": "07:00",
    }


def test_schedules_read_naturally():
    assert describe_schedule({"kind": "daily", "time": "07:00"}) == "Every day at 07:00"
    assert describe_schedule({"kind": "weekdays", "time": "08:30"}) == "Weekdays at 08:30"
    assert describe_schedule({"kind": "weekly", "time": "09:00", "days": [1]}) == (
        "Every Monday at 09:00"
    )
    assert describe_schedule({"kind": "weekly", "time": "09:00", "days": [1, 4, 5]}) == (
        "Every Monday, Thursday and Friday at 09:00"
    )
    assert describe_schedule({"kind": "monthly", "time": "08:00", "day_of_month": 1}) == (
        "On the 1st of every month at 08:00"
    )
    assert describe_schedule({"kind": "monthly", "time": "08:00", "day_of_month": 22}) == (
        "On the 22nd of every month at 08:00"
    )
