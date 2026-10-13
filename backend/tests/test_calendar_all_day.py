"""Unit tests: all-day Google Calendar events use an exclusive end date."""

import uuid

import pytest

from app.integrations import engine
from app.models.entity import Entity
from app.services import calendar_service


def test_all_day_range_ends_the_next_day():
    start, end = calendar_service._all_day_range("2026-10-13")

    assert start == {"date": "2026-10-13"}
    assert end == {"date": "2026-10-14"}


def test_all_day_range_crosses_month_and_year():
    assert calendar_service._all_day_range("2026-12-31")[1] == {"date": "2027-01-01"}


class _Response:
    status_code = 200
    text = ""

    def json(self):
        return {}


class _FakeClient:
    def __init__(self, calls):
        self.calls = calls

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_exc):
        return False

    async def post(self, url, headers=None, json=None):
        self.calls.append(json)
        return _Response()


def _event(metadata):
    return Entity(
        user_id=uuid.uuid4(),
        entity_type="event",
        name="Conferenza",
        content=None,
        metadata_=metadata,
    )


@pytest.mark.asyncio
async def test_integration_all_day_event_has_exclusive_end(monkeypatch):
    calls = []
    monkeypatch.setattr(engine.httpx, "AsyncClient", lambda: _FakeClient(calls))

    await engine._google_calendar_create_event(
        {"access_token": "token"}, _event({"event_date": "2026-10-13"})
    )

    assert calls[0]["start"] == {"date": "2026-10-13"}
    assert calls[0]["end"] == {"date": "2026-10-14"}


@pytest.mark.asyncio
async def test_integration_skips_non_iso_event_date(monkeypatch):
    calls = []
    monkeypatch.setattr(engine.httpx, "AsyncClient", lambda: _FakeClient(calls))

    await engine._google_calendar_create_event(
        {"access_token": "token"}, _event({"event_date": "venerdì"})
    )

    assert calls == []
