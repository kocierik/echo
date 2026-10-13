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
    assert client.calls["tools_get"][0] == "u1"


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


def _fn(slug):
    return {"type": "function", "function": {"name": slug}}


class BigToolkitsClient(StubClient):
    """tools.get by slug / by toolkit (honouring limit) and the raw `important` listing."""

    def __init__(self, active):
        super().__init__(active=active)
        self.catalog = {
            tk: [f"{tk.upper()}_TOOL_{i:03d}" for i in range(150)]
            for tk in ("gmail", "slack", "asana")
        }
        self.catalog["gmail"] += ["GMAIL_SEND_EMAIL", "GMAIL_CREATE_EMAIL_DRAFT"]
        self.important = {"gmail": ["GMAIL_TOOL_149"], "slack": ["SLACK_TOOL_120"]}
        self.get_calls = []
        self.list_calls = []
        self.client = _ns(tools=_ns(list=self._raw_list))

    def _tools_get(self, user_id, **kw):
        self.get_calls.append(kw)
        if kw.get("tools") is not None:
            known = {s for slugs in self.catalog.values() for s in slugs}
            return [_fn(s) for s in kw["tools"] if s in known]
        slugs = [s for tk in kw["toolkits"] for s in self.catalog.get(tk, [])]
        return [_fn(s) for s in slugs[: kw.get("limit") or len(slugs)]]

    def _raw_list(self, **kw):
        self.list_calls.append(kw)
        tks = kw["toolkit_slug"].split(",")
        return _ns(items=[_ns(slug=s) for tk in tks for s in self.important.get(tk, [])])


async def test_tools_for_caps_offered_tools_and_keeps_required_ones():
    client = BigToolkitsClient(active=["gmail", "slack", "asana"])
    tools = await ComposioActionProvider(client=client).tools_for(
        "u1", ["asana", "gmail", "slack"]
    )
    names = [t["function"]["name"] for t in tools]
    assert len(names) == len(set(names)) == composio_provider.MAX_OFFERED_TOOLS == 100
    # Required write tools and the important ones are always there
    for slug in ("GMAIL_SEND_EMAIL", "GMAIL_CREATE_EMAIL_DRAFT", "GMAIL_TOOL_149",
                 "SLACK_TOOL_120"):
        assert slug in names
    # Every connected toolkit gets some tools; initial toolkits come first
    assert any(n.startswith("ASANA_") for n in names)
    toolkit_order = [n.split("_")[0] for n in names]
    assert toolkit_order.index("ASANA") > max(
        i for i, tk in enumerate(toolkit_order) if tk in ("GMAIL", "SLACK")
    )
    # The required slugs were fetched explicitly, the important ones only for initial toolkits
    by_slug = [c["tools"] for c in client.get_calls if c.get("tools") is not None]
    assert any("GMAIL_SEND_EMAIL" in slugs for slugs in by_slug)
    assert all("SLACK_SEND_MESSAGE" in slugs for slugs in by_slug[:1])
    assert [c["toolkit_slug"] for c in client.list_calls] == ["gmail,slack"]
    assert client.list_calls[0]["important"] == "true"


async def test_tools_for_survives_a_failing_important_listing():
    client = BigToolkitsClient(active=["gmail"])

    def broken(**kw):
        raise RuntimeError("no such filter")

    client.client = _ns(tools=_ns(list=broken))
    tools = await ComposioActionProvider(client=client).tools_for("u1", ["gmail"])
    names = [t["function"]["name"] for t in tools]
    assert "GMAIL_SEND_EMAIL" in names and len(names) == 100


async def test_execute_timeout_is_an_unknown_outcome(monkeypatch):
    import time

    from app.actions.provider import ActionOutcomeUnknown

    class Slow(StubClient):
        def _execute(self, slug, arguments, **kw):
            time.sleep(0.3)
            return {"successful": True, "data": {}}

    monkeypatch.setattr(composio_provider, "SDK_TIMEOUT_SECONDS", 0.05)
    with pytest.raises(ActionOutcomeUnknown):
        await ComposioActionProvider(client=Slow(active=["gmail"])).execute(
            "u1", "GMAIL_SEND_EMAIL", {}
        )


async def test_execute_sdk_timeout_error_is_unknown_but_other_errors_are_not():
    from app.actions.provider import ActionOutcomeUnknown

    class APITimeoutError(Exception):
        pass

    timeout = StubClient(active=["gmail"], execute_error=APITimeoutError("read timeout"))
    with pytest.raises(ActionOutcomeUnknown):
        await ComposioActionProvider(client=timeout).execute("u1", "GMAIL_SEND_EMAIL", {})

    refused = StubClient(active=["gmail"], execute_error=ConnectionError("refused"))
    with pytest.raises(ActionProviderError) as exc:
        await ComposioActionProvider(client=refused).execute("u1", "GMAIL_SEND_EMAIL", {})
    assert not isinstance(exc.value, ActionOutcomeUnknown)


async def test_lookup_timeout_is_a_plain_provider_error(monkeypatch):
    import time

    from app.actions.provider import ActionOutcomeUnknown

    class SlowList(StubClient):
        def _list(self, **kw):
            time.sleep(0.3)
            return _ns(items=[])

    monkeypatch.setattr(composio_provider, "SDK_TIMEOUT_SECONDS", 0.05)
    with pytest.raises(ActionProviderError) as exc:
        await ComposioActionProvider(client=SlowList()).connected_toolkits("u1")
    assert not isinstance(exc.value, ActionOutcomeUnknown)
