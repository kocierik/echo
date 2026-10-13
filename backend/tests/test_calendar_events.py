"""Unit tests: Google Calendar event dates, times and durations."""

import uuid

import pytest

from app.core.config import settings
from app.integrations import engine
from app.models.entity import Entity
from app.services import calendar_service, chat_actions
from app.services.calendar_service import (
    all_day_range,
    event_schedule_from_metadata,
    rescheduled_range,
    timed_range,
)

TZ = settings.user_timezone


# --- Ranges ---


def test_all_day_range_ends_the_next_day():
    start, end = all_day_range("2026-10-13")

    assert start == {"date": "2026-10-13"}
    assert end == {"date": "2026-10-14"}


def test_all_day_range_crosses_month_and_year():
    assert all_day_range("2026-12-31")[1] == {"date": "2027-01-01"}


def test_timed_range_uses_duration_and_user_timezone():
    start, end = timed_range("2026-10-13", "23:30", 60)

    assert start == {"dateTime": "2026-10-13T23:30:00", "timeZone": TZ}
    assert end == {"dateTime": "2026-10-14T00:30:00", "timeZone": TZ}


def test_timed_range_accepts_seconds():
    assert timed_range("2026-10-13", "15:00:00", 30)[1]["dateTime"] == "2026-10-13T15:30:00"


# --- Rescheduling keeps what the user did not change ---

TIMED_EVENT = {
    "start": {"dateTime": "2026-10-13T15:00:00+02:00", "timeZone": "Europe/Rome"},
    "end": {"dateTime": "2026-10-13T17:00:00+02:00", "timeZone": "Europe/Rome"},
}
ALL_DAY_EVENT = {"start": {"date": "2026-10-13"}, "end": {"date": "2026-10-14"}}


def test_new_time_keeps_day_and_duration():
    start, end = rescheduled_range(TIMED_EVENT, time="18:00")

    assert start["dateTime"] == "2026-10-13T18:00:00"
    assert end["dateTime"] == "2026-10-13T20:00:00"


def test_new_date_keeps_time_and_duration():
    start, end = rescheduled_range(TIMED_EVENT, date="2026-10-20")

    assert start["dateTime"] == "2026-10-20T15:00:00"
    assert end["dateTime"] == "2026-10-20T17:00:00"


def test_new_duration_keeps_start():
    start, end = rescheduled_range(TIMED_EVENT, duration_minutes=30)

    assert start["dateTime"] == "2026-10-13T15:00:00"
    assert end["dateTime"] == "2026-10-13T15:30:00"


def test_all_day_event_moved_to_another_day_stays_all_day():
    assert rescheduled_range(ALL_DAY_EVENT, date="2026-10-20") == all_day_range("2026-10-20")


def test_all_day_event_given_a_time_lasts_default_duration():
    start, end = rescheduled_range(ALL_DAY_EVENT, time="09:00")

    assert start["dateTime"] == "2026-10-13T09:00:00"
    assert end["dateTime"] == "2026-10-13T10:00:00"


# --- Extracted metadata validation ---


def test_schedule_from_complete_metadata():
    metadata = {"event_date": "2026-10-13", "event_time": "15:00", "duration_minutes": 90}

    assert event_schedule_from_metadata(metadata) == ("2026-10-13", "15:00", 90)


def test_schedule_without_time_is_all_day_and_due_date_is_accepted():
    assert event_schedule_from_metadata({"due_date": "2026-10-13"}) == ("2026-10-13", None, None)


@pytest.mark.parametrize("metadata", [{}, None, {"event_date": "venerdì"}, {"event_date": 3}])
def test_schedule_without_iso_date_is_rejected(metadata):
    assert event_schedule_from_metadata(metadata) is None


def test_schedule_drops_invalid_time_and_duration():
    metadata = {"event_date": "2026-10-13", "event_time": "pomeriggio", "duration_minutes": "2h"}

    assert event_schedule_from_metadata(metadata) == ("2026-10-13", None, None)


@pytest.mark.parametrize(
    ("value", "expected"), [(45, 45), ("30", 30), (0, None), (-5, None), ("x", None), (None, None)]
)
def test_chat_duration_param_parsing(value, expected):
    assert chat_actions._positive_int(value) == expected


# --- HTTP payloads ---


class _Response:
    def __init__(self, status_code=200, payload=None):
        self.status_code = status_code
        self.text = ""
        self._payload = payload or {}

    def json(self):
        return self._payload


class _FakeClient:
    def __init__(self, calls, existing=None):
        self.calls = calls
        self.existing = existing

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_exc):
        return False

    async def post(self, url, headers=None, json=None):
        self.calls.append(("post", json))
        return _Response()

    async def get(self, url, headers=None):
        self.calls.append(("get", url))
        return _Response(payload=self.existing)

    async def patch(self, url, headers=None, json=None):
        self.calls.append(("patch", json))
        return _Response(payload=json)


def _event(metadata):
    return Entity(
        user_id=uuid.uuid4(),
        entity_type="event",
        name="Conferenza",
        content=None,
        metadata_=metadata,
    )


@pytest.fixture
def calendar_posts(monkeypatch):
    calls = []

    async def fake_token(_db, _user_id):
        return "token"

    monkeypatch.setattr(calendar_service, "get_calendar_token", fake_token)
    monkeypatch.setattr(calendar_service.httpx, "AsyncClient", lambda: _FakeClient(calls))
    return calls


@pytest.mark.asyncio
async def test_integration_all_day_event_has_exclusive_end(calendar_posts):
    await engine.create_calendar_event_for_entity(
        None, uuid.uuid4(), _event({"event_date": "2026-10-13"})
    )

    body = calendar_posts[0][1]
    assert body["start"] == {"date": "2026-10-13"}
    assert body["end"] == {"date": "2026-10-14"}


@pytest.mark.asyncio
async def test_integration_timed_event_defaults_to_one_hour(calendar_posts):
    await engine.create_calendar_event_for_entity(
        None, uuid.uuid4(), _event({"event_date": "2026-10-13", "event_time": "15:00"})
    )

    body = calendar_posts[0][1]
    assert body["start"] == {"dateTime": "2026-10-13T15:00:00", "timeZone": TZ}
    assert body["end"] == {"dateTime": "2026-10-13T16:00:00", "timeZone": TZ}


@pytest.mark.asyncio
async def test_integration_timed_event_uses_extracted_duration(calendar_posts):
    metadata = {"event_date": "2026-10-13", "event_time": "15:00", "duration_minutes": 120}

    await engine.create_calendar_event_for_entity(None, uuid.uuid4(), _event(metadata))

    assert calendar_posts[0][1]["end"]["dateTime"] == "2026-10-13T17:00:00"


@pytest.mark.asyncio
async def test_integration_skips_non_iso_event_date(calendar_posts):
    result = await engine.create_calendar_event_for_entity(
        None, uuid.uuid4(), _event({"event_date": "venerdì"})
    )

    assert result is None
    assert calendar_posts == []


@pytest.mark.asyncio
async def test_update_with_time_only_keeps_existing_day_and_duration(monkeypatch):
    calls = []

    async def fake_token(_db, _user_id):
        return "token"

    monkeypatch.setattr(calendar_service, "get_calendar_token", fake_token)
    monkeypatch.setattr(
        calendar_service.httpx, "AsyncClient", lambda: _FakeClient(calls, TIMED_EVENT)
    )

    result = await calendar_service.update_event(None, uuid.uuid4(), "evt1", time="18:00")

    assert calls[0][0] == "get"
    method, body = calls[1]
    assert method == "patch"
    assert body["start"]["dateTime"] == "2026-10-13T18:00:00"
    assert body["end"]["dateTime"] == "2026-10-13T20:00:00"
    assert result == body


@pytest.mark.asyncio
async def test_update_of_summary_only_does_not_touch_schedule(monkeypatch):
    calls = []

    async def fake_token(_db, _user_id):
        return "token"

    monkeypatch.setattr(calendar_service, "get_calendar_token", fake_token)
    monkeypatch.setattr(
        calendar_service.httpx, "AsyncClient", lambda: _FakeClient(calls, TIMED_EVENT)
    )

    await calendar_service.update_event(None, uuid.uuid4(), "evt1", summary="Nuovo nome")

    assert calls == [("patch", {"summary": "Nuovo nome"})]
