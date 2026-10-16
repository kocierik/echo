"""Reminders and Calendar on the iPhone: the app runs them, the server waits for the answer."""

import asyncio
import uuid

import pytest

from app.actions import phone_provider as phone
from app.actions.agent import _system_prompt, run_action_agent
from app.actions.availability import APP_NAMES, _apps_section, _parse_intent
from app.actions.policy import ToolTier, classify_call
from app.actions.provider import (
    AccountNotConnectedError,
    ActionOutcomeUnknown,
    ActionProviderError,
    ToolResult,
)
from app.models.action_log import ActionLog
from app.routers import query as q
from app.services.device_commands import take_device_commands
from app.services.llm_base import LLMResponse, LLMToolCall
from tests.conftest import TEST_USER_ID
from tests.fakes.action_provider import FakeActionProvider
from tests.fakes.redis import InMemoryRedis
from tests.mocks import MockLLMService

USER = str(TEST_USER_ID)
REMINDER = {"title": "Comprare il latte", "due": "2026-10-16T18:00"}


class WaitingRedis(InMemoryRedis):
    """`blpop` waits for a value, up to its timeout, as Redis does."""

    async def blpop(self, keys, timeout=0):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            found = await super().blpop(keys, timeout)
            if found is not None or loop.time() >= deadline:
                return found
            await asyncio.sleep(0.01)


@pytest.fixture
def redis(client):
    fake = WaitingRedis()
    client._transport.app.state.redis = fake
    return fake


async def _the_app_answers(client, auth_headers, result: dict) -> dict:
    """What the app does: picks the command up, then posts what the iPhone did."""
    for _ in range(100):
        response = await client.get("/api/device/commands?wait=1", headers=auth_headers)
        if commands := response.json()["commands"]:
            break
    [command] = commands
    posted = await client.post(
        f"/api/device/commands/{command['id']}/result", headers=auth_headers, json=result
    )
    assert posted.status_code == 204
    return command


def test_creating_runs_at_once_and_reading_is_a_read():
    assert set(phone.TOOLS) == {
        "APPLEREMINDERS_CREATE_REMINDER",
        "APPLEREMINDERS_LIST_REMINDERS",
        "APPLECALENDAR_CREATE_EVENT",
        "APPLECALENDAR_LIST_EVENTS",
    }
    assert classify_call("APPLEREMINDERS_CREATE_REMINDER", REMINDER) == ToolTier.CREATE
    event = {"title": "Cena", "start": "2026-10-16T20:00"}
    assert classify_call("APPLECALENDAR_CREATE_EVENT", event) == ToolTier.CREATE
    assert classify_call("APPLEREMINDERS_LIST_REMINDERS", {}) == ToolTier.READ
    assert classify_call("APPLECALENDAR_LIST_EVENTS", {}) == ToolTier.READ


@pytest.mark.asyncio
async def test_the_app_says_which_iphone_apps_are_on(client, auth_headers, redis):
    response = await client.put(
        "/api/device/phone-apps", headers=auth_headers, json={"reminders": True}
    )
    assert response.json() == {"reminders": True, "calendar": False}
    assert await phone.phone_apps(redis, USER) == ["applereminders"]

    await client.put(
        "/api/device/phone-apps", headers=auth_headers, json={"reminders": True, "calendar": True}
    )
    assert await phone.phone_apps(redis, USER) == ["applereminders", "applecalendar"]
    assert redis.ttls[phone.PHONE_APPS_KEY.format(user_id=USER)] == phone.PHONE_APPS_TTL_S


@pytest.mark.asyncio
async def test_a_reminder_is_made_by_the_app_and_its_answer_returned(client, auth_headers, redis):
    await phone.set_phone_apps(redis, USER, ["applereminders"])
    provider = phone.PhoneActionProvider(redis)
    run = asyncio.create_task(
        provider.execute(USER, "APPLEREMINDERS_CREATE_REMINDER", REMINDER)
    )

    command = await _the_app_answers(
        client, auth_headers, {"ok": True, "data": {"id": "r1", "title": "Comprare il latte"}}
    )

    assert command["type"] == "phone_action"
    assert command["tool"] == "APPLEREMINDERS_CREATE_REMINDER"
    assert command["arguments"] == REMINDER
    result = await asyncio.wait_for(run, 2)
    assert result == ToolResult(ok=True, data={"id": "r1", "title": "Comprare il latte"})


@pytest.mark.asyncio
async def test_what_the_iphone_could_not_do_is_the_tool_error(client, auth_headers, redis):
    await phone.set_phone_apps(redis, USER, ["applereminders"])
    provider = phone.PhoneActionProvider(redis)
    run = asyncio.create_task(
        provider.execute(USER, "APPLEREMINDERS_CREATE_REMINDER", REMINDER)
    )

    await _the_app_answers(
        client, auth_headers, {"ok": False, "error": "Echo has no access to Reminders"}
    )

    result = await asyncio.wait_for(run, 2)
    assert result == ToolResult(ok=False, error="Echo has no access to Reminders")


@pytest.mark.asyncio
async def test_an_iphone_that_never_picks_up_did_nothing(redis, monkeypatch):
    monkeypatch.setattr(phone, "RESULT_WAIT_S", 0.05)
    await phone.set_phone_apps(redis, USER, ["applecalendar"])

    with pytest.raises(ActionProviderError) as raised:
        await phone.PhoneActionProvider(redis).execute(
            USER, "APPLECALENDAR_CREATE_EVENT", {"title": "Cena", "start": "2026-10-16T20:00"}
        )

    assert not isinstance(raised.value, ActionOutcomeUnknown)
    assert "could not be reached" in str(raised.value)


@pytest.mark.asyncio
async def test_picked_up_but_never_answered_may_have_run(redis, monkeypatch):
    monkeypatch.setattr(phone, "RESULT_WAIT_S", 0.3)
    await phone.set_phone_apps(redis, USER, ["applecalendar"])
    run = asyncio.create_task(
        phone.PhoneActionProvider(redis).execute(
            USER, "APPLECALENDAR_CREATE_EVENT", {"title": "Cena", "start": "2026-10-16T20:00"}
        )
    )

    for _ in range(50):
        if await take_device_commands(redis, TEST_USER_ID, 0):
            break
        await asyncio.sleep(0.01)

    with pytest.raises(ActionOutcomeUnknown):
        await run


@pytest.mark.asyncio
async def test_an_app_that_is_off_is_not_connected(redis):
    with pytest.raises(AccountNotConnectedError):
        await phone.PhoneActionProvider(redis).execute(
            USER, "APPLEREMINDERS_CREATE_REMINDER", REMINDER
        )


@pytest.mark.asyncio
async def test_results_only_for_the_users_own_live_commands(client, auth_headers, redis):
    unknown = uuid.uuid4().hex
    post = lambda command_id: client.post(  # noqa: E731
        f"/api/device/commands/{command_id}/result", headers=auth_headers, json={"ok": True}
    )
    assert (await post(unknown)).status_code == 404
    await redis.set(phone.OWNER_KEY.format(command_id=unknown), str(uuid.uuid4()))
    assert (await post(unknown)).status_code == 404  # someone else's
    assert (await post("not-a-command")).status_code == 404


@pytest.mark.asyncio
async def test_without_iphone_apps_nothing_changes(redis):
    composio = FakeActionProvider(connected={"gmail"})
    assert await phone.with_phone_apps(composio, redis, USER) is composio
    assert await phone.with_phone_apps(None, redis, USER) is None


@pytest.mark.asyncio
async def test_with_iphone_apps_each_provider_runs_its_own_tools(redis):
    schema = {"type": "function", "function": {"name": "GMAIL_SEND_EMAIL", "parameters": {}}}
    composio = FakeActionProvider(connected={"gmail"}, tools={"GMAIL_SEND_EMAIL": schema})
    await phone.set_phone_apps(redis, USER, ["applecalendar"])

    provider = await phone.with_phone_apps(composio, redis, USER)

    assert await provider.connected_toolkits(USER) == ["gmail", "applecalendar"]
    tools = await provider.tools_for(USER, ["gmail", "applecalendar"])
    assert [t["function"]["name"] for t in tools] == [
        "GMAIL_SEND_EMAIL",
        "APPLECALENDAR_CREATE_EVENT",
        "APPLECALENDAR_LIST_EVENTS",
    ]
    await provider.execute(USER, "GMAIL_SEND_EMAIL", {"to": "ada@x.it"})
    assert composio.executed == [("GMAIL_SEND_EMAIL", {"to": "ada@x.it"})]

    # A server without Composio: the iPhone's apps alone
    alone = await phone.with_phone_apps(None, redis, USER)
    assert await alone.connected_toolkits(USER) == ["applecalendar"]
    with pytest.raises(AccountNotConnectedError):
        await alone.execute(USER, "GMAIL_SEND_EMAIL", {})


def test_the_router_names_the_phone_apps_only_when_they_are_on():
    section = _apps_section(["gmail", "applereminders"], APP_NAMES)
    assert "applereminders (Phone Reminders)" in section
    assert "applereminders" not in section.split("NOT connected")[1]

    on = _parse_intent(
        {"needs_apps": True, "apps": ["Phone Reminders"]}, ["applereminders"], APP_NAMES
    )
    assert on.apps == ["applereminders"]
    off = _parse_intent({"needs_apps": True, "apps": ["Phone Reminders"]}, ["gmail"], APP_NAMES)
    assert off.apps == [] and off.unresolved == ["Phone Reminders"]


def test_the_model_hears_of_a_phone_not_an_iphone():
    # The calendar runs on Android phones too: the answer must not say "your iPhone"
    words = repr(phone.TOOLS) + repr(phone.PHONE_APP_NAMES) + _system_prompt(phone_apps=True)
    assert "iPhone" not in words
    assert "Apple" not in words


def test_reminder_requests_are_checked_for_apps():
    assert q.might_need_tools("Ricordami di comprare il latte alle 18", [])
    assert q.might_need_tools("Remind me to call Ada tomorrow", [])
    assert q.might_need_tools("Che promemoria ho?", [])
    assert not q.might_need_tools("Ti ricordi cosa ha detto Marco?", [])


def test_the_agent_knows_what_an_iphone_reminder_does():
    assert "applereminders" in _system_prompt(phone_apps=True)
    assert "applereminders" not in _system_prompt()


class _FakeSession:
    def __init__(self):
        self.rows = []

    def add(self, obj):
        self.rows.append(obj)

    async def flush(self):
        pass


class _ScriptedLLM(MockLLMService):
    def __init__(self, responses):
        super().__init__()
        self.tool_responses = list(responses)
        self.prompts: list[str] = []
        self.offered: list[list[str]] = []

    async def complete_with_tools(self, messages, tools, temperature=0.2):
        self.prompts.append(messages[0].content)
        self.offered.append([t["function"]["name"] for t in tools])
        return await super().complete_with_tools(messages, tools, temperature)


class _Phone(phone.PhoneActionProvider):
    """The iPhone answering at once."""

    def __init__(self):
        super().__init__(InMemoryRedis())
        self.executed = []

    async def execute(self, user_id, tool, arguments):
        self.executed.append((tool, arguments))
        return ToolResult(ok=True, data={"id": "r1", **arguments})


@pytest.mark.asyncio
async def test_the_agent_makes_the_reminder_at_once_and_logs_it():
    iphone = _Phone()
    provider = phone.WithPhoneApps(None, iphone, ["applereminders"])
    llm = _ScriptedLLM([
        LLMResponse(
            content="",
            model="mock",
            tool_calls=[LLMToolCall("c0", "APPLEREMINDERS_CREATE_REMINDER", REMINDER)],
        ),
        LLMResponse(content="Fatto: domani alle 18 ti ricordo il latte.", model="mock"),
    ])
    db = _FakeSession()

    outcome = await run_action_agent(
        db, TEST_USER_ID, "Ricordami di comprare il latte domani alle 18", [],
        session_id=None, source="voice", provider=provider, llm=llm,
        connected_toolkits=["applereminders"],
    )

    assert outcome.pending_action is None
    assert outcome.executed_tools == ["APPLEREMINDERS_CREATE_REMINDER"]
    assert iphone.executed == [("APPLEREMINDERS_CREATE_REMINDER", REMINDER)]
    assert "APPLEREMINDERS_CREATE_REMINDER" in llm.offered[0]
    assert "applereminders" in llm.prompts[0]
    [log] = [row for row in db.rows if isinstance(row, ActionLog)]
    assert log.tool == "APPLEREMINDERS_CREATE_REMINDER"
