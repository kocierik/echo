"""Unit tests: explicit /query date filters with open ends."""

from datetime import datetime, timezone

from app.services import memory_answers as query
from app.services.temporal import DateRange

START = datetime(2026, 10, 1, tzinfo=timezone.utc)
END = datetime(2026, 10, 13, 23, 59, tzinfo=timezone.utc)


def test_naive_bounds_become_utc_and_aware_bounds_are_kept():
    naive = datetime(2026, 10, 1, 8, 0)
    aware = datetime(2026, 10, 1, 8, 0, tzinfo=timezone.utc)

    assert query.as_utc(naive) == aware
    assert query.as_utc(aware) is aware
    assert query.as_utc(None) is None


def test_period_description_handles_open_ends():
    assert query.describe_period(DateRange(START, END)) == "01/10/2026 - 13/10/2026"
    assert query.describe_period(DateRange(START, None)) == "from 01/10/2026 onwards"
    assert query.describe_period(DateRange(None, END)) == "until 13/10/2026"


def test_date_filter_response_handles_open_ends():
    assert query.format_date_filter(None) is None
    assert query.format_date_filter(DateRange(None, END)) == {
        "from": None,
        "to": END.isoformat(),
    }
    assert query.format_date_filter(DateRange(START, None)) == {
        "from": START.isoformat(),
        "to": None,
    }


def test_open_range_repr_does_not_crash():
    assert "…" in repr(DateRange(None, END))
