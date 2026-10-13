"""Unit tests: shared integration clients used by both integrations and rules."""

import uuid

import pytest

from app.integrations import clients, engine
from app.models.entity import Entity
from app.services import rules_engine


class _Response:
    def __init__(self, status_code=200):
        self.status_code = status_code
        self.text = ""


class _Recorder:
    """httpx.AsyncClient stand-in recording every POST."""

    def __init__(self, calls, status_code=200):
        self.calls = calls
        self.status_code = status_code

    def __call__(self, *args, **kwargs):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_exc):
        return False

    async def post(self, url, headers=None, json=None):
        self.calls.append({"url": url, "headers": headers or {}, "json": json})
        return _Response(self.status_code)


@pytest.fixture
def calls(monkeypatch):
    recorded = []
    monkeypatch.setattr(clients.httpx, "AsyncClient", _Recorder(recorded))
    return recorded


def _task(**metadata):
    return Entity(
        user_id=uuid.uuid4(),
        entity_type="task",
        name="Call Ada",
        content="About Project Atlas",
        metadata_=metadata,
    )


# --- Todoist (API v1: REST v2 answers 410 Gone) ---


@pytest.mark.asyncio
async def test_todoist_task_uses_the_v1_api(calls):
    await clients.create_todoist_task({"api_token": "tok"}, _task())

    assert calls[0]["url"] == "https://api.todoist.com/api/v1/tasks"
    assert calls[0]["headers"]["Authorization"] == "Bearer tok"
    assert calls[0]["json"] == {
        "content": "Call Ada",
        "description": "About Project Atlas",
        "priority": 1,
    }


@pytest.mark.asyncio
async def test_todoist_task_maps_priority_due_date_and_project(calls):
    await clients.create_todoist_task(
        {"api_token": "tok", "project_id": "p1"},
        _task(priority="high", due_date="2026-10-14"),
    )

    assert calls[0]["json"]["priority"] == 4
    assert calls[0]["json"]["due_string"] == "2026-10-14"
    assert calls[0]["json"]["project_id"] == "p1"


@pytest.mark.asyncio
async def test_todoist_without_token_sends_nothing(calls):
    assert await clients.create_todoist_task({}, _task()) is False
    assert calls == []


@pytest.mark.asyncio
async def test_todoist_reports_failure_status(monkeypatch):
    recorded = []
    monkeypatch.setattr(clients.httpx, "AsyncClient", _Recorder(recorded, status_code=410))

    assert await clients.create_todoist_task({"api_token": "tok"}, _task()) is False


# --- Notion, Telegram, Slack ---


@pytest.mark.asyncio
async def test_notion_page_has_title_and_content_block(calls):
    await clients.create_notion_page({"api_key": "key", "database_id": "db"}, _task())

    body = calls[0]["json"]
    assert calls[0]["url"] == "https://api.notion.com/v1/pages"
    assert body["parent"] == {"database_id": "db"}
    assert body["properties"]["Name"]["title"][0]["text"]["content"] == "Call Ada"
    assert body["children"][0]["paragraph"]["rich_text"][0]["text"]["content"] == (
        "About Project Atlas"
    )


@pytest.mark.asyncio
async def test_telegram_message_uses_the_given_heading(calls):
    await clients.send_telegram_message(
        {"bot_token": "bot", "chat_id": "42"}, _task(), heading="Rule triggered"
    )

    assert calls[0]["url"] == "https://api.telegram.org/botbot/sendMessage"
    assert calls[0]["json"]["chat_id"] == "42"
    assert calls[0]["json"]["text"].startswith("Rule triggered")
    assert "[TASK] Call Ada" in calls[0]["json"]["text"]


@pytest.mark.asyncio
async def test_slack_message_goes_to_the_webhook(calls):
    await clients.send_slack_message({"webhook_url": "https://hooks.test/x"}, _task())

    assert calls[0]["url"] == "https://hooks.test/x"
    assert "[TASK]" in calls[0]["json"]["text"]
    assert "Call Ada" in calls[0]["json"]["text"]


# --- Both callers share the clients ---


@pytest.mark.asyncio
async def test_integration_and_rule_create_the_same_todoist_task(calls):
    integration = type("I", (), {"provider": "todoist", "config": {"api_token": "tok"}})()

    await engine._execute_integration(None, uuid.uuid4(), integration, _task())
    await rules_engine._execute_actions(
        [{"type": "todoist", "api_token": "tok"}], _task(), None, uuid.uuid4()
    )

    assert [c["url"] for c in calls] == ["https://api.todoist.com/api/v1/tasks"] * 2
    assert calls[0]["json"] == calls[1]["json"]


@pytest.mark.asyncio
async def test_calendar_integration_goes_through_the_calendar_service(monkeypatch):
    created = []

    async def fake_create_event(db, user_id, **kwargs):
        created.append(kwargs)
        return {"id": "evt"}

    monkeypatch.setattr(engine, "create_event", fake_create_event)
    integration = type("I", (), {"provider": "google_calendar", "config": {}})()
    event = Entity(
        user_id=uuid.uuid4(),
        entity_type="event",
        name="Dentist",
        content=None,
        metadata_={"event_date": "2026-10-14", "event_time": "15:00", "duration_minutes": 30},
    )

    await engine._execute_integration(None, uuid.uuid4(), integration, event)

    assert created == [{
        "summary": "Dentist",
        "date": "2026-10-14",
        "time": "15:00",
        "location": None,
        "description": None,
        "duration_minutes": 30,
    }]
