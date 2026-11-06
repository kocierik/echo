"""Keys with permissions: phones and scripts are `full` (the REST API), connected apps
(Claude, Cursor…) are `read` and work only on the MCP server."""

import types
import uuid
from datetime import datetime, timezone

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app.core import auth
from app.models.api_key import ApiKey
from app.models.conversation import Conversation
from tests.conftest import TEST_API_KEY, TEST_USER_ID
from tests.factories import make_conversation
from tests.fakes.redis import InMemoryRedis


async def _connect(client, auth_headers, name="Claude Code"):
    return await client.post(
        "/api/auth/connected-apps", headers=auth_headers, json={"name": name}
    )


async def test_existing_and_phone_keys_are_full(client, auth_headers, db_session):
    devices = (await client.get("/api/auth/devices", headers=auth_headers)).json()

    assert {d["scope"] for d in devices} == {"full"}


async def test_a_connected_app_key_is_read_and_shown_once(client, auth_headers):
    response = await _connect(client, auth_headers)

    assert response.status_code == 201
    body = response.json()
    assert body["name"] == "Claude Code" and len(body["api_key"]) > 20
    devices = (await client.get("/api/auth/devices", headers=auth_headers)).json()
    app = next(d for d in devices if d["id"] == body["id"])
    assert app["scope"] == "read"
    assert "api_key" not in app and "key_hash" not in app


async def test_read_keys_are_refused_by_the_rest_api(client, auth_headers, db_session):
    conversation, _ = await make_conversation(
        db_session, started_at=datetime(2026, 10, 13, 9, tzinfo=timezone.utc)
    )
    read = {"X-API-Key": (await _connect(client, auth_headers)).json()["api_key"]}
    redis = client._transport.app.state.redis

    for method, path in [
        ("GET", "/api/conversations"),
        ("GET", "/api/export"),
        ("DELETE", f"/api/conversations/{conversation.id}"),
        ("GET", "/metrics"),
    ]:
        response = await client.request(method, path, headers=read)
        assert response.status_code == 403, (method, path, response.text)
        assert response.json()["detail"] == "This key is for connected apps only."

    still = await db_session.scalar(select(Conversation).where(Conversation.id == conversation.id))
    assert still is not None
    # Not a wrong key: nothing counted against the address
    assert not [key for key in redis.values if str(key).startswith("auth_fail:")]


async def test_at_most_ten_connected_apps(client, auth_headers):
    for i in range(10):
        assert (await _connect(client, auth_headers, f"App {i}")).status_code == 201

    eleventh = await _connect(client, auth_headers, "One more")

    assert eleventh.status_code == 409
    assert eleventh.json()["detail"] == "At most 10 connected apps."


async def test_revoking_a_connected_app(client, auth_headers, db_session):
    app_id = (await _connect(client, auth_headers)).json()["id"]

    response = await client.delete(f"/api/auth/devices/{app_id}", headers=auth_headers)

    assert response.status_code == 204
    assert await db_session.get(ApiKey, uuid.UUID(app_id)) is None


def _bearer_request(redis, key):
    app = types.SimpleNamespace(state=types.SimpleNamespace(redis=redis))
    return types.SimpleNamespace(
        app=app,
        client=types.SimpleNamespace(host="10.0.0.9"),
        headers={"authorization": f"Bearer {key}"} if key else {},
    )


async def test_authenticate_connected_app(client, auth_headers, db_session):
    read_key = (await _connect(client, auth_headers)).json()["api_key"]
    redis = InMemoryRedis()

    key = await auth.authenticate_connected_app(_bearer_request(redis, read_key), db_session)
    assert key.scope == "read" and key.user_id == TEST_USER_ID
    assert key.last_used_at is not None

    with pytest.raises(HTTPException) as phone:
        await auth.authenticate_connected_app(
            _bearer_request(redis, TEST_API_KEY), db_session
        )
    assert phone.value.status_code == 401
    assert phone.value.detail == "Use a connected app's key"

    with pytest.raises(HTTPException) as missing:
        await auth.authenticate_connected_app(_bearer_request(redis, None), db_session)
    assert missing.value.status_code == 401

    with pytest.raises(HTTPException) as unknown:
        await auth.authenticate_connected_app(_bearer_request(redis, "nope"), db_session)
    assert unknown.value.status_code == 401
    # Counted apart from the REST API's failures
    assert await redis.get("mcp_auth_fail:10.0.0.9") == b"1"
    assert await redis.get("auth_fail:10.0.0.9") is None


async def test_a_revoked_connected_app_is_not_counted_as_a_wrong_key(client, auth_headers,
                                                                     db_session):
    created = (await _connect(client, auth_headers)).json()
    await client.delete(f"/api/auth/devices/{created['id']}", headers=auth_headers)
    redis = client._transport.app.state.redis

    with pytest.raises(HTTPException):
        await auth.authenticate_connected_app(
            _bearer_request(redis, created["api_key"]), db_session
        )

    assert await redis.get("mcp_auth_fail:10.0.0.9") is None


async def test_metrics_accept_a_full_key(client, auth_headers):
    # It answered 500 for any API key: the check was called without the request
    assert (await client.get("/metrics", headers=auth_headers)).status_code == 200


async def test_a_key_deleted_while_its_request_runs_fails_nothing(db_session, monkeypatch):
    """Signing out while the app still loads Profile: a request in flight with that key
    finishes, instead of a 500 when its commit marks a key that is gone as used."""
    from tests.conftest import test_session

    key = "a-key-signed-out-meanwhile"
    async with test_session() as db:
        db.add(ApiKey(user_id=TEST_USER_ID, key_hash=auth.hash_api_key(key), name="iPhone"))
        await db.commit()
    mark_used = auth._mark_used

    async def signed_out_first(db, record):
        # Another request signs out between this one reading the key and marking it used
        async with test_session() as other:
            await other.delete(await other.get(ApiKey, record.id))
            await other.commit()
        await mark_used(db, record)

    monkeypatch.setattr(auth, "_mark_used", signed_out_first)
    request = types.SimpleNamespace(
        app=types.SimpleNamespace(state=types.SimpleNamespace(redis=InMemoryRedis())),
        client=types.SimpleNamespace(host="1.2.3.4"),
        headers={},
        state=types.SimpleNamespace(),
    )

    record = await auth.get_current_api_key(request, api_key=key, db=db_session)
    await db_session.commit()

    assert record.last_used_at is not None
