from types import SimpleNamespace

import pytest

from app.actions import composio_provider
from app.actions.composio_provider import ComposioActionProvider, get_action_provider
from app.actions.provider import (
    INITIAL_TOOLKITS,
    AccountNotConnectedError,
    ActionProviderError,
    ToolResult,
)


def _ns(**kw):
    return SimpleNamespace(**kw)


class StubClient:
    def __init__(self, active=(), execute_result=None, execute_error=None, auth_configs=()):
        self.active = [_ns(id=f"ca_{s}", toolkit=_ns(slug=s), status="ACTIVE") for s in active]
        self.calls = {}
        self.deleted = []
        self.execute_result = execute_result
        self.execute_error = execute_error
        self.auth_config_items = [_ns(id=i, created_at="2026-01-01") for i in auth_configs]
        self.connected_accounts = _ns(list=self._list, link=self._link, delete=self._delete)
        self.tools = _ns(get=self._tools_get, execute=self._execute)
        self.toolkits = _ns(get=self._toolkits_get)
        self.auth_configs = _ns(list=self._ac_list, create=self._ac_create)

    def _list(self, **kw):
        self.calls["list"] = kw
        slugs = kw.get("toolkit_slugs")
        items = [a for a in self.active if not slugs or a.toolkit.slug in slugs]
        return _ns(items=items)

    def _link(self, user_id, auth_config_id, **kw):
        self.calls["link"] = (user_id, auth_config_id, kw)
        return _ns(redirect_url="https://connect.example/abc")

    def _delete(self, nanoid, **kw):
        self.deleted.append(nanoid)

    def _tools_get(self, user_id, **kw):
        self.calls["tools_get"] = (user_id, kw)
        return [{"type": "function", "function": {"name": "GMAIL_FETCH_EMAILS"}}]

    def _execute(self, slug, arguments, **kw):
        self.calls["execute"] = (slug, arguments, kw)
        if self.execute_error:
            raise self.execute_error
        return self.execute_result

    def _toolkits_get(self, slug=None, *, query=None):
        if slug:
            return _ns(slug=slug, name=slug.title(), meta=_ns(description=f"{slug} desc"))
        self.calls["toolkits_query"] = query
        return [_ns(slug="asana", name="Asana", meta=_ns(description="tasks"))]

    def _ac_list(self, **kw):
        return _ns(items=self.auth_config_items)

    def _ac_create(self, **kw):
        return _ns(auth_config=_ns(id="ac_new"))


async def test_execute_maps_success_and_failure():
    ok = StubClient(active=["gmail"], execute_result={"successful": True, "data": {"id": 1}})
    p = ComposioActionProvider(client=ok)
    assert await p.execute("u1", "GMAIL_FETCH_EMAILS", {"a": 1}) == ToolResult(
        ok=True, data={"id": 1}
    )
    slug, args, kw = ok.calls["execute"]
    assert (slug, args, kw["user_id"]) == ("GMAIL_FETCH_EMAILS", {"a": 1}, "u1")

    bad = StubClient(
        active=["gmail"], execute_result={"successful": False, "data": {}, "error": "boom"}
    )
    r = await ComposioActionProvider(client=bad).execute("u1", "GMAIL_FETCH_EMAILS", {})
    assert r == ToolResult(ok=False, error="boom")

    err = StubClient(active=["gmail"], execute_error=RuntimeError("secret-ish"))
    with pytest.raises(ActionProviderError) as exc:
        await ComposioActionProvider(client=err).execute("u1", "GMAIL_FETCH_EMAILS", {})
    assert "secret-ish" not in str(exc.value)


async def test_execute_without_connected_account_raises_account_not_connected():
    p = ComposioActionProvider(client=StubClient(active=["slack"]))
    with pytest.raises(AccountNotConnectedError) as exc:
        await p.execute("u1", "GMAIL_FETCH_EMAILS", {})
    assert exc.value.toolkit == "gmail"


async def test_list_toolkits_marks_connected_ones():
    p = ComposioActionProvider(client=StubClient(active=["slack"]))
    toolkits = await p.list_toolkits("u1")
    assert [t.slug for t in toolkits] == list(INITIAL_TOOLKITS)
    assert {t.slug for t in toolkits if t.connected} == {"slack"}


async def test_list_toolkits_with_query_searches():
    client = StubClient(active=["asana"])
    toolkits = await ComposioActionProvider(client=client).list_toolkits("u1", query="asa")
    assert [(t.slug, t.connected) for t in toolkits] == [("asana", True)]
    assert client.calls["toolkits_query"]["search"] == "asa"


async def test_connect_link_returns_redirect_url():
    client = StubClient(auth_configs=["ac_1"])
    url = await ComposioActionProvider(client=client).connect_link(
        "u1", "gmail", "https://app/cb"
    )
    assert url == "https://connect.example/abc"
    assert client.calls["link"] == ("u1", "ac_1", {"callback_url": "https://app/cb"})


async def test_connect_link_creates_managed_auth_config_when_missing():
    client = StubClient()
    await ComposioActionProvider(client=client).connect_link("u1", "gmail", None)
    assert client.calls["link"][1] == "ac_new"


async def test_disconnect_deletes_the_active_account():
    client = StubClient(active=["gmail", "slack"])
    await ComposioActionProvider(client=client).disconnect("u1", "gmail")
    assert client.deleted == ["ca_gmail"]


async def test_tools_for_returns_openai_schemas():
    client = StubClient(active=["gmail"])
    p = ComposioActionProvider(client=client)
    assert await p.tools_for("u1", []) == []
    tools = await p.tools_for("u1", ["gmail"])
    assert tools[0]["function"]["name"] == "GMAIL_FETCH_EMAILS"
    assert client.calls["tools_get"] == ("u1", {"toolkits": ["gmail"]})


async def test_missing_api_key_is_a_clear_error(monkeypatch):
    monkeypatch.setattr(composio_provider.settings, "composio_api_key", "")
    get_action_provider.cache_clear()
    with pytest.raises(ActionProviderError, match="Composio is not configured"):
        get_action_provider()


async def test_get_action_provider_is_a_singleton(monkeypatch):
    monkeypatch.setattr(composio_provider.settings, "composio_api_key", "k")
    get_action_provider.cache_clear()
    assert get_action_provider() is get_action_provider()
    get_action_provider.cache_clear()


async def test_connected_toolkits_is_one_accounts_call():
    client = StubClient(active=["gmail", "asana", "gmail"])
    toolkits = await ComposioActionProvider(client=client).connected_toolkits("u1")
    assert toolkits == ["gmail", "asana"]
    assert client.calls["list"] == {"user_ids": ["u1"], "statuses": ["ACTIVE"]}


async def test_list_toolkits_includes_connected_toolkits_found_by_search():
    client = StubClient(active=["slack", "asana"])
    toolkits = await ComposioActionProvider(client=client).list_toolkits("u1")
    assert [t.slug for t in toolkits] == [*INITIAL_TOOLKITS, "asana"]
    asana = toolkits[-1]
    assert (asana.name, asana.description, asana.connected) == ("Asana", "asana desc", True)
    assert await ComposioActionProvider(client=client).connected_toolkits("u1") == [
        "slack", "asana",
    ]
