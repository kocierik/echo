"""HTTP-level tests of the actions router: real dependency wiring, no database.

The router runs in a FastAPI app through TestClient: the real X-API-Key check
(`get_current_user_id`), the real provider dependency and real query parsing. Only
`get_db` is overridden, with a fake session that answers the API-key lookup, the
voice-session query and (with none) the routine runs query.
"""

import uuid
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.actions.provider import ActionProviderError
from app.core.auth import hash_api_key
from app.core.database import get_db
from app.routers import actions as r

USER = uuid.UUID("b0000000-0000-0000-0000-000000000002")
GOOD_KEY = "good-key"


class _Result:
    def __init__(self, rows):
        self._rows = rows

    def scalar_one_or_none(self):
        return self._rows[0] if self._rows else None

    def scalars(self):
        return SimpleNamespace(all=lambda: list(self._rows))


class FakeSession:
    def __init__(self):
        self.voice_session = None
        self.committed = 0

    async def execute(self, stmt):
        sql = str(stmt)
        if "api_keys" in sql:
            params = stmt.compile().params.values()
            if hash_api_key(GOOD_KEY) in params:
                return _Result([SimpleNamespace(user_id=USER, last_used_at=None)])
            return _Result([])
        if "chat_sessions" in sql:
            return _Result([self.voice_session] if self.voice_session else [])
        raise AssertionError(f"unexpected query: {sql}")

    async def scalars(self, stmt):
        # The routine runs /voice-updates also brings: none here (tests/test_routine_runs_api.py)
        assert "routine_runs" in str(stmt), f"unexpected query: {stmt}"
        return []

    async def commit(self):
        self.committed += 1

    async def rollback(self):
        pass


@pytest.fixture
def http():
    session = FakeSession()
    app = FastAPI()
    app.include_router(r.router, prefix="/api")

    async def fake_get_db():
        yield session

    app.dependency_overrides[get_db] = fake_get_db
    with TestClient(app) as client:
        yield SimpleNamespace(client=client, db=session)


def _auth():
    return {"X-API-Key": GOOD_KEY}


def test_missing_api_key_is_rejected(http):
    res = http.client.get("/api/actions/voice-updates")
    # No key at all: 401 (FastAPI 0.162; 403 before)
    assert res.status_code == 401


def test_invalid_api_key_is_401(http):
    res = http.client.get("/api/actions/voice-updates", headers={"X-API-Key": "wrong"})
    assert res.status_code == 401
    assert res.json()["detail"] == "Invalid API key"


def test_provider_not_configured_is_503(http, monkeypatch):
    def unconfigured():
        raise ActionProviderError("Composio is not configured")

    monkeypatch.setattr(r, "get_action_provider", unconfigured)
    res = http.client.get("/api/actions/toolkits", headers=_auth())
    assert res.status_code == 503
    assert res.json() == {"detail": "Composio is not configured"}


def test_auth_is_checked_before_the_provider(http, monkeypatch):
    def unconfigured():
        raise ActionProviderError("Composio is not configured")

    monkeypatch.setattr(r, "get_action_provider", unconfigured)
    assert http.client.get("/api/actions/toolkits").status_code == 401


def test_overridden_user_reaches_the_provider(http, monkeypatch):
    from app.core.auth import get_current_user_id
    from tests.fakes.action_provider import FakeActionProvider

    seen = []

    class Provider(FakeActionProvider):
        async def list_toolkits(self, user_id, query=None):
            seen.append(user_id)
            return await super().list_toolkits(user_id, query)

    monkeypatch.setattr(r, "get_action_provider", lambda: Provider(connected={"gmail"}))
    http.client.app.dependency_overrides[get_current_user_id] = lambda: USER
    res = http.client.get("/api/actions/toolkits")
    assert res.status_code == 200
    assert seen == [str(USER)]
    assert {"slug": "gmail", "connected": True}.items() <= res.json()[0].items()


def _voice_session(*timestamps):
    return SimpleNamespace(
        id=uuid.uuid4(),
        messages=[
            {"role": "assistant", "content": f"m{i}", "timestamp": ts}
            for i, ts in enumerate(timestamps)
        ],
    )


def test_voice_updates_since_with_z_suffix(http):
    http.db.voice_session = _voice_session(
        "2026-10-14T09:59:59+00:00", "2026-10-14T10:00:00+00:00", "2026-10-14T10:00:01+00:00"
    )
    res = http.client.get(
        "/api/actions/voice-updates?since=2026-10-14T10:00:00Z", headers=_auth()
    )
    assert res.status_code == 200
    assert [m["content"] for m in res.json()["messages"]] == ["m2"]


def test_voice_updates_since_with_encoded_offset(http):
    # 10:00+02:00 is 08:00 UTC; "%2B" is the "+" (a raw "+" would decode to a space)
    http.db.voice_session = _voice_session(
        "2026-10-14T07:59:00+00:00", "2026-10-14T08:00:00+00:00", "2026-10-14T08:30:00+00:00"
    )
    res = http.client.get(
        "/api/actions/voice-updates?since=2026-10-14T10:00:00%2B02:00", headers=_auth()
    )
    assert res.status_code == 200
    assert [m["content"] for m in res.json()["messages"]] == ["m2"]


def test_voice_updates_rejects_an_invalid_since(http):
    res = http.client.get("/api/actions/voice-updates?since=yesterday", headers=_auth())
    assert res.status_code == 422
