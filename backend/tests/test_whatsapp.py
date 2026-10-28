"""WhatsApp, read-only, through the bridge (whatsapp/): the app links and unlinks it, and
the action agent reads the user's private chats with two tools, only when it is linked."""

import json
import uuid
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from app.actions.agent import NO_APPS
from app.actions.availability import not_connected_answer
from app.actions.policy import ToolTier, classify_tool
from app.actions.whatsapp_provider import LIST_CHATS, READ_CHAT, with_whatsapp
from app.core.config import settings
from app.routers.query import might_need_tools
from app.services import whatsapp_bridge
from app.services.whatsapp_bridge import WhatsAppBridge
from tests.conftest import TEST_USER_ID
from tests.fakes.redis import InMemoryRedis

MARCO = "393331112222@s.whatsapp.net"


class _Bridge:
    """What the bridge answers, and what it was asked."""

    def __init__(self, state="linked"):
        self.state = state
        self.asked: list[httpx.Request] = []
        self.down = False
        self.link_status = 0

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.asked.append(request)
        if self.down:
            raise httpx.ConnectError("down")
        assert request.headers["X-Bridge-Token"] == "secret"
        path = request.url.path
        if path.endswith("/status"):
            phone = "+393330000000" if self.state == "linked" else None
            return httpx.Response(200, json={"state": self.state, "phone": phone})
        if path.endswith("/link"):
            if self.link_status:
                return httpx.Response(self.link_status, json={"error": "WhatsApp did not answer"})
            if self.state == "linked":
                return httpx.Response(409, json={"error": "already linked"})
            return httpx.Response(200, json={"code": "ABCD1234"})
        if request.method == "DELETE":
            return httpx.Response(204)
        if path.endswith("/chats"):
            return httpx.Response(200, json={"chats": [{
                "chat": MARCO, "name": "Marco", "last_at": "2026-10-28T08:00:00Z",
                "last_text": "Alle 9?", "last_from_me": False, "count": 3,
            }]})
        if path.endswith("/messages"):
            return httpx.Response(200, json={"messages": [
                {"chat": MARCO, "name": "Marco", "from_me": False, "text": "Alle 9?",
                 "at": "2026-10-28T08:00:00Z"},
                {"chat": MARCO, "name": "Marco", "from_me": True, "text": "Sì",
                 "at": "2026-10-28T08:01:00Z"},
            ]})
        return httpx.Response(404)


@pytest.fixture
def bridge(monkeypatch):
    fake = _Bridge()
    monkeypatch.setattr(settings, "whatsapp_bridge_url", "http://whatsapp:3100")
    monkeypatch.setattr(settings, "whatsapp_bridge_token", "secret")
    monkeypatch.setattr(
        whatsapp_bridge,
        "get_bridge",
        # Like the real one: none without a URL
        lambda: WhatsAppBridge(
            "http://whatsapp:3100", "secret", transport=httpx.MockTransport(fake.handler)
        ) if settings.whatsapp_bridge_url else None,
    )
    return fake


async def test_without_a_bridge_it_is_not_available(client, auth_headers, monkeypatch):
    monkeypatch.setattr(settings, "whatsapp_bridge_url", "")

    response = await client.get("/api/whatsapp", headers=auth_headers)

    assert response.json() == {"available": False, "state": "unlinked", "phone": None}


async def test_status_comes_from_the_bridge(client, auth_headers, bridge):
    response = await client.get("/api/whatsapp", headers=auth_headers)

    assert response.json() == {"available": True, "state": "linked", "phone": "+393330000000"}
    assert bridge.asked[0].url.path == f"/users/{TEST_USER_ID}/status"


async def test_a_bridge_that_cannot_be_reached_says_so(client, auth_headers, bridge):
    bridge.down = True

    response = await client.get("/api/whatsapp", headers=auth_headers)

    assert response.json() == {"available": True, "state": "unreachable", "phone": None}


async def test_linking_gives_the_pairing_code(client, auth_headers, bridge):
    bridge.state = "unlinked"

    response = await client.post(
        "/api/whatsapp/link", headers=auth_headers, json={"phone": "+39 333 000 0000"}
    )

    assert response.json() == {"code": "ABCD1234"}
    assert json.loads(bridge.asked[0].content) == {"phone": "+39 333 000 0000"}


async def test_a_number_without_its_country_code_is_refused(client, auth_headers, bridge):
    bridge.state = "unlinked"

    response = await client.post(
        "/api/whatsapp/link", headers=auth_headers, json={"phone": "333 000 0000"}
    )

    assert response.status_code == 422
    assert bridge.asked == []


async def test_whatsapp_not_answering_in_time_says_so(client, auth_headers, bridge):
    bridge.state = "unlinked"
    bridge.link_status = 504

    response = await client.post(
        "/api/whatsapp/link", headers=auth_headers, json={"phone": "+393330000000"}
    )

    assert response.status_code == 504


async def test_linking_twice_is_a_conflict(client, auth_headers, bridge):
    response = await client.post(
        "/api/whatsapp/link", headers=auth_headers, json={"phone": "+393330000000"}
    )

    assert response.status_code == 409


async def test_unlinking(client, auth_headers, bridge):
    response = await client.delete("/api/whatsapp", headers=auth_headers)

    assert response.status_code == 204
    assert bridge.asked[0].method == "DELETE"


async def test_not_configured_or_not_linked_changes_nothing(bridge, monkeypatch):
    redis = InMemoryRedis()
    bridge.state = "unlinked"
    assert await with_whatsapp(NO_APPS, redis, TEST_USER_ID) is NO_APPS

    monkeypatch.setattr(settings, "whatsapp_bridge_url", "")
    bridge.state = "linked"
    assert await with_whatsapp(NO_APPS, InMemoryRedis(), TEST_USER_ID) is NO_APPS


async def test_a_bridge_that_is_down_changes_nothing(bridge):
    bridge.down = True

    assert await with_whatsapp(None, InMemoryRedis(), TEST_USER_ID) is None


async def test_linked_whatsapp_is_an_app_with_two_read_tools(bridge):
    provider = await with_whatsapp(NO_APPS, InMemoryRedis(), TEST_USER_ID)

    assert await provider.connected_toolkits(str(TEST_USER_ID)) == ["whatsapp"]
    tools = await provider.tools_for(str(TEST_USER_ID), ["whatsapp"])
    names = [t["function"]["name"] for t in tools]
    assert names == [LIST_CHATS, READ_CHAT]
    assert {classify_tool(name) for name in names} == {ToolTier.READ}


async def test_the_status_is_asked_once_a_minute(bridge):
    redis = InMemoryRedis()

    await with_whatsapp(NO_APPS, redis, TEST_USER_ID)
    await with_whatsapp(NO_APPS, redis, TEST_USER_ID)

    assert len(bridge.asked) == 1


async def test_the_tools_read_the_bridge(bridge):
    provider = await with_whatsapp(NO_APPS, InMemoryRedis(), TEST_USER_ID)
    user = str(TEST_USER_ID)

    chats = await provider.execute(user, LIST_CHATS, {})
    assert chats.ok and chats.data["chats"][0]["name"] == "Marco"

    since = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
    messages = await provider.execute(user, READ_CHAT, {"person": "Marco", "since": since})
    assert messages.ok
    assert [m["from"] for m in messages.data["messages"]] == ["Marco", "you"]
    asked = bridge.asked[-1].url.params
    assert (asked["name"], asked["since"]) == ("Marco", since)


async def test_a_failing_read_is_a_failed_tool_not_a_crash(bridge):
    provider = await with_whatsapp(NO_APPS, InMemoryRedis(), TEST_USER_ID)
    bridge.down = True

    result = await provider.execute(str(TEST_USER_ID), READ_CHAT, {"person": "Marco"})

    assert result.ok is False


async def test_other_apps_still_go_to_their_provider(bridge):
    class _Composio:
        async def connected_toolkits(self, user_id, **kwargs):
            return ["gmail"]

        async def tools_for(self, user_id, toolkits):
            return [{"type": "function", "function": {"name": "GMAIL_FETCH_EMAILS"}}]

        async def execute(self, user_id, tool, arguments):
            from app.actions.provider import ToolResult

            return ToolResult(ok=True, data={"from": "composio"})

    provider = await with_whatsapp(_Composio(), InMemoryRedis(), TEST_USER_ID)

    assert await provider.connected_toolkits(str(TEST_USER_ID)) == ["gmail", "whatsapp"]
    tools = await provider.tools_for(str(TEST_USER_ID), ["gmail", "whatsapp"])
    assert len(tools) == 3
    gmail = await provider.execute(str(TEST_USER_ID), "GMAIL_FETCH_EMAILS", {})
    assert gmail.data == {"from": "composio"}


@pytest.mark.parametrize("question", [
    "cosa mi ha scritto Marco?",
    "What did Marco write me?",
    "what did Ada write me on WhatsApp?",
    "Marco mi ha risposto?",
    "cosa mi ha mandato Giulia?",
    "any chat from Ada?",
    "did Ada answer?",
])
def test_ways_of_asking_about_messages_may_need_an_app(bridge, question):
    assert might_need_tools(question, [])


def test_without_a_bridge_those_words_go_to_memory_as_before(monkeypatch):
    monkeypatch.setattr(settings, "whatsapp_bridge_url", "")

    assert not might_need_tools("cosa mi ha scritto Marco?", [])
    assert not might_need_tools("Marco mi ha risposto?", [])


def test_without_a_bridge_whatsapp_is_not_said_to_be_in_profile(monkeypatch):
    monkeypatch.setattr(settings, "whatsapp_bridge_url", "")

    assert "Profile → WhatsApp" not in not_connected_answer("leggi WhatsApp", "whatsapp")


async def test_a_bridge_that_is_down_is_not_asked_again_at_once(bridge):
    bridge.down = True
    redis = InMemoryRedis()

    await with_whatsapp(NO_APPS, redis, TEST_USER_ID)
    await with_whatsapp(NO_APPS, redis, TEST_USER_ID)

    assert len(bridge.asked) == 1


async def test_an_apps_outage_does_not_hide_whatsapp(bridge):
    from app.actions.provider import ActionProviderError

    class _Down:
        async def connected_toolkits(self, user_id, **kwargs):
            raise ActionProviderError("composio down")

        async def tools_for(self, user_id, toolkits):
            raise ActionProviderError("composio down")

    provider = await with_whatsapp(_Down(), InMemoryRedis(), TEST_USER_ID)

    assert await provider.connected_toolkits(str(TEST_USER_ID)) == ["whatsapp"]
    tools = await provider.tools_for(str(TEST_USER_ID), ["gmail", "whatsapp"])
    assert [t["function"]["name"] for t in tools] == [LIST_CHATS, READ_CHAT]


async def test_messages_carry_the_chat_name_and_the_users_local_time(bridge, monkeypatch):
    monkeypatch.setattr(settings, "user_timezone", "Europe/Rome")
    provider = await with_whatsapp(NO_APPS, InMemoryRedis(), TEST_USER_ID)

    result = await provider.execute(
        str(TEST_USER_ID), READ_CHAT, {"person": "Marco", "since": "2026-10-28T09:00"}
    )

    first, mine = result.data["messages"]
    assert (mine["from"], mine["chat_name"]) == ("you", "Marco")
    # 08:00 UTC is 09:00 in Rome (CET)
    assert first["at"].startswith("2026-10-28T09:00:00+01:00")
    # A time without a zone is the user's
    assert bridge.asked[-1].url.params["since"] == "2026-10-28T09:00:00+01:00"


def test_whatsapp_not_linked_says_where_to_link_it(bridge):
    assert "Profile → WhatsApp" in not_connected_answer("cosa mi ha scritto Marco?", "whatsapp")


async def test_a_routine_reads_whatsapp_when_it_is_linked(bridge):
    from tests.test_routines_worker import _LLM, _routine, _run

    await _routine(instruction="ogni sera riassumimi i messaggi WhatsApp")
    llm = _LLM()

    await _run(llm, redis=InMemoryRedis())

    offered = {tool["function"]["name"] for tool in llm.tools_log[0]}
    assert {LIST_CHATS, READ_CHAT} <= offered


async def test_the_bridge_client_sends_the_token_and_the_user(bridge):
    status = await whatsapp_bridge.get_bridge().status(uuid.UUID(int=1))

    assert status["state"] == "linked"
    assert bridge.asked[0].url.path == f"/users/{uuid.UUID(int=1)}/status"
