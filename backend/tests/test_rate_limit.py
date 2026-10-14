"""Rate limits are counted per API key (hashed), falling back to the client IP.

Behind Cloudflare Tunnel every request has the same client IP, so an IP budget would be
shared by every key. The real app runs through TestClient with the real X-API-Key check;
only `get_db` is overridden and the query answer is stubbed.
"""

import hashlib
import uuid
from contextlib import contextmanager
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from starlette.requests import Request

from app.core import rate_limit
from app.core.auth import get_current_user_id, hash_api_key
from app.core.database import get_db
from app.main import app
from app.routers import query, segments

KEY_A = "key-a-very-secret"
KEY_B = "key-b-very-secret"
USER = uuid.UUID("c0000000-0000-0000-0000-000000000003")


def _request(headers=None, client=("203.0.113.7", 1234)) -> Request:
    raw = [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()]
    return Request({"type": "http", "headers": raw, "client": client})


class _Result:
    def __init__(self, row):
        self._row = row

    def scalar_one_or_none(self):
        return self._row


class _Session:
    async def execute(self, stmt):
        params = stmt.compile().params.values()
        known = {hash_api_key(KEY_A), hash_api_key(KEY_B)}
        hit = next((p for p in params if p in known), None)
        return _Result(SimpleNamespace(user_id=USER, last_used_at=None) if hit else None)

    async def commit(self):
        pass

    async def rollback(self):
        pass


@contextmanager
def _app_client(monkeypatch):
    """The real app with a fake DB; the overrides found on entry are restored on exit
    (the integration conftest installs its own get_db override at import)."""

    async def fake_db():
        yield _Session()

    async def fake_answer(redis_client, body, user_id, db, progress=None):
        return query.QueryResponse(answer="ok", sources=[], session_id=str(uuid.uuid4()))

    monkeypatch.setattr(query, "_answer_query", fake_answer)
    previous = dict(app.dependency_overrides)
    app.dependency_overrides[get_db] = fake_db
    rate_limit.limiter.reset()
    try:
        with TestClient(app) as c:
            yield c
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(previous)
        rate_limit.limiter.reset()


@pytest.fixture
def client(monkeypatch):
    with _app_client(monkeypatch) as c:
        yield c


def test_the_client_restores_the_overrides_it_found(monkeypatch):
    async def conftest_db():
        yield None

    app.dependency_overrides[get_db] = conftest_db
    try:
        with _app_client(monkeypatch):
            app.dependency_overrides[get_current_user_id] = lambda: USER
        assert app.dependency_overrides == {get_db: conftest_db}
    finally:
        app.dependency_overrides.pop(get_db, None)


def _ask(client, key=None):
    headers = {"X-API-Key": key} if key else {}
    return client.post("/api/query", json={"question": "ciao"}, headers=headers)


def test_limiter_key_is_the_hashed_api_key():
    key = rate_limit.rate_limit_key(_request({"X-API-Key": KEY_A}))
    assert key == "key:" + hashlib.sha256(KEY_A.encode()).hexdigest()[:16]
    assert KEY_A not in key


def test_limiter_key_without_api_key_is_the_client_ip():
    assert rate_limit.rate_limit_key(_request()) == "203.0.113.7"
    assert rate_limit.rate_limit_key(_request({"X-API-Key": ""})) == "203.0.113.7"


def test_one_shared_limiter_with_the_same_limits():
    assert query.limiter is rate_limit.limiter
    assert segments.limiter is rate_limit.limiter
    assert app.state.limiter is rate_limit.limiter

    # slowapi has no public way to list a route's limits: read the private registry so a
    # changed decorator string fails here (the 429 tests below cover only the query route)
    def limits(name):
        return [str(item.limit) for item in rate_limit.limiter._route_limits[name]]

    assert limits("app.routers.query.query_memory") == ["20 per 1 minute"]
    assert limits("app.routers.segments.ingest_segment") == ["60 per 1 minute"]


def test_the_21st_query_with_the_same_key_is_429(client):
    for _ in range(20):
        assert _ask(client, KEY_A).status_code == 200
    assert _ask(client, KEY_A).status_code == 429


def test_two_keys_from_the_same_ip_have_separate_budgets(client):
    for _ in range(20):
        assert _ask(client, KEY_A).status_code == 200
    assert _ask(client, KEY_A).status_code == 429
    assert _ask(client, KEY_B).status_code == 200


def test_requests_without_a_key_share_the_ip_budget(client):
    app.dependency_overrides[get_current_user_id] = lambda: USER  # no key needed here
    for _ in range(20):
        assert _ask(client).status_code == 200
    assert _ask(client).status_code == 429
    # A key has its own budget even from the same IP
    assert _ask(client, KEY_A).status_code == 200


def test_raw_key_is_never_logged(client, caplog):
    caplog.set_level("DEBUG")
    for _ in range(21):
        _ask(client, KEY_A)
    assert KEY_A not in caplog.text
