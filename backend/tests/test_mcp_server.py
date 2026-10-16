"""The MCP server at /mcp: only connected apps' read keys, a limit per key, and the
Streamable HTTP protocol as Claude Code or Cursor speak it."""

import pytest

from app.mcp import server as mcp_server
from tests.conftest import TEST_API_KEY

HEADERS = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
INITIALIZE = {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": {"name": "pytest", "version": "0"},
}


async def rpc(client, key, method, params=None, id=1):
    headers = dict(HEADERS)
    if key is not None:
        headers["Authorization"] = f"Bearer {key}"
    body = {"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}
    return await client.post("/mcp", headers=headers, json=body)


async def connected_app(client, auth_headers, name="Claude Code"):
    response = await client.post(
        "/api/auth/connected-apps", headers=auth_headers, json={"name": name}
    )
    return response.json()


async def test_no_key_or_a_phone_key_gets_401(client):
    assert (await rpc(client, None, "tools/list")).status_code == 401
    phone = await rpc(client, TEST_API_KEY, "tools/list")
    assert phone.status_code == 401
    assert phone.json()["detail"] == "Use a connected app's key"


async def test_a_connected_app_can_initialize_and_list_tools(client, auth_headers):
    key = (await connected_app(client, auth_headers))["api_key"]

    init = await rpc(client, key, "initialize", INITIALIZE)
    assert init.status_code == 200, init.text
    result = init.json()["result"]
    assert result["serverInfo"]["name"] == "Echo"
    assert "Read-only" in result["instructions"]

    tools = await rpc(client, key, "tools/list", id=2)
    assert tools.status_code == 200
    assert isinstance(tools.json()["result"]["tools"], list)


async def test_a_revoked_connected_app_gets_401_and_is_not_locked_out(client, auth_headers):
    app = await connected_app(client, auth_headers)
    await client.delete(f"/api/auth/devices/{app['id']}", headers=auth_headers)

    statuses = {(await rpc(client, app["api_key"], "tools/list")).status_code for _ in range(15)}

    assert statuses == {401}


async def test_more_than_the_limit_a_minute_get_429(client, auth_headers, monkeypatch):
    assert mcp_server.MCP_CALLS_PER_MINUTE == 60
    monkeypatch.setattr(mcp_server, "MCP_CALLS_PER_MINUTE", 3)
    key = (await connected_app(client, auth_headers))["api_key"]

    for i in range(3):
        assert (await rpc(client, key, "tools/list", id=i)).status_code == 200
    over = await rpc(client, key, "tools/list", id=9)

    assert over.status_code == 429
    assert int(over.headers["Retry-After"]) > 0


@pytest.mark.parametrize("path", ["/mcp", "/mcp/"])
async def test_the_address_works_with_or_without_the_slash(client, auth_headers, path):
    key = (await connected_app(client, auth_headers))["api_key"]
    headers = {**HEADERS, "Authorization": f"Bearer {key}"}
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}

    response = await client.post(path, headers=headers, json=body)

    assert response.status_code == 200
