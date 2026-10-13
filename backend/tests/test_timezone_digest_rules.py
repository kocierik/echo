"""Unit tests: digest schedule in the user's timezone, metrics auth."""

from datetime import date, datetime, timezone
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app import main
from app.core.timezone import local_day_bounds
from app.workers.digest import next_digest_run

# --- Local day bounds and digest schedule (Europe/Rome, digest at 04:00) ---


def test_local_day_bounds_are_local_midnights():
    start, end = local_day_bounds(date(2026, 10, 13))

    assert start.isoformat() == "2026-10-13T00:00:00+02:00"
    assert end.isoformat() == "2026-10-14T00:00:00+02:00"
    assert start.astimezone(timezone.utc).hour == 22  # previous UTC day


def test_digest_runs_tonight_at_four_for_the_day_just_ended():
    now = datetime(2026, 10, 13, 20, 0, tzinfo=timezone.utc)  # 22:00 in Rome

    run_at, day = next_digest_run(now)

    assert run_at.isoformat() == "2026-10-14T04:00:00+02:00"
    assert day == date(2026, 10, 13)


def test_digest_after_midnight_but_before_four_runs_the_same_night():
    now = datetime(2026, 10, 13, 23, 30, tzinfo=timezone.utc)  # 01:30 on the 14th in Rome

    run_at, day = next_digest_run(now)

    assert run_at.isoformat() == "2026-10-14T04:00:00+02:00"
    assert day == date(2026, 10, 13)


def test_digest_after_four_waits_for_the_next_night():
    now = datetime(2026, 10, 14, 3, 0, tzinfo=timezone.utc)  # 05:00 in Rome

    run_at, day = next_digest_run(now)

    assert run_at.isoformat() == "2026-10-15T04:00:00+02:00"
    assert day == date(2026, 10, 14)


# --- /metrics authorization ---


def _request(headers):
    return SimpleNamespace(headers=headers)


@pytest.mark.asyncio
async def test_metrics_accepts_the_configured_bearer_token(monkeypatch):
    monkeypatch.setattr(main.settings, "metrics_token", "scrape-secret")

    await main._authorize_metrics(_request({"authorization": "Bearer scrape-secret"}))


@pytest.mark.asyncio
async def test_metrics_rejects_missing_or_wrong_credentials(monkeypatch):
    monkeypatch.setattr(main.settings, "metrics_token", "scrape-secret")

    for headers in ({}, {"authorization": "Bearer nope"}):
        with pytest.raises(HTTPException) as exc:
            await main._authorize_metrics(_request(headers))
        assert exc.value.status_code == 401
