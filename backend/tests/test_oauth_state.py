"""Unit tests: signed OAuth state and the Google callback's CSRF/replay checks."""

import uuid
from types import SimpleNamespace

import pytest

from app.core.oauth_state import STATE_TTL_S, InvalidOAuthStateError, create_state, verify_state
from app.routers import oauth

SECRET = "test-secret"
USER_ID = uuid.UUID("a0000000-0000-0000-0000-000000000001")
NOW = 1_800_000_000


def test_valid_state_round_trips_user_and_nonce():
    state = create_state(USER_ID, SECRET, now=NOW)

    user_id, nonce = verify_state(state, SECRET, now=NOW + 1)

    assert user_id == USER_ID
    assert nonce


def test_states_are_unique():
    assert create_state(USER_ID, SECRET, now=NOW) != create_state(USER_ID, SECRET, now=NOW)


@pytest.mark.parametrize(
    "state",
    [
        str(USER_ID),  # the old format: plain user id
        "",
        "a.b.c.d",
        f"{USER_ID}.{NOW + 600}.nonce.deadbeef",
    ],
)
def test_forged_or_malformed_state_is_rejected(state):
    with pytest.raises(InvalidOAuthStateError):
        verify_state(state, SECRET, now=NOW)


def test_tampered_user_id_is_rejected():
    _, expires, nonce, signature = create_state(USER_ID, SECRET, now=NOW).split(".")
    forged = f"{uuid.uuid4()}.{expires}.{nonce}.{signature}"

    with pytest.raises(InvalidOAuthStateError):
        verify_state(forged, SECRET, now=NOW)


def test_state_signed_with_another_secret_is_rejected():
    with pytest.raises(InvalidOAuthStateError):
        verify_state(create_state(USER_ID, "other", now=NOW), SECRET, now=NOW)


def test_expired_state_is_rejected():
    state = create_state(USER_ID, SECRET, now=NOW)

    with pytest.raises(InvalidOAuthStateError):
        verify_state(state, SECRET, now=NOW + STATE_TTL_S + 1)


def test_missing_secret_is_an_error():
    with pytest.raises(ValueError):
        create_state(USER_ID, "", now=NOW)
    with pytest.raises(InvalidOAuthStateError):
        verify_state("x", "", now=NOW)


# --- Callback ---


class _FakeRedis:
    def __init__(self):
        self.keys = set()

    async def set(self, key, value, nx=False, ex=None):
        if nx and key in self.keys:
            return None
        self.keys.add(key)
        return True


class _Result:
    def scalar_one_or_none(self):
        return None


class _FakeDb:
    def __init__(self):
        self.added = []
        self.committed = False

    async def execute(self, _query):
        return _Result()

    def add(self, obj):
        self.added.append(obj)

    async def commit(self):
        self.committed = True


class _TokenResponse:
    status_code = 200
    text = ""

    def json(self):
        return {"access_token": "access", "refresh_token": "refresh"}


class _FakeClient:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *_exc):
        return False

    async def post(self, url, data=None):
        return _TokenResponse()


@pytest.fixture
def callback_env(monkeypatch):
    monkeypatch.setattr(oauth.settings, "oauth_state_secret", SECRET)
    monkeypatch.setattr(oauth.httpx, "AsyncClient", lambda: _FakeClient())
    redis = _FakeRedis()
    request = SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace(redis=redis)))
    return request


@pytest.mark.asyncio
async def test_callback_rejects_plain_user_id_state(callback_env):
    db = _FakeDb()

    response = await oauth.google_callback(callback_env, code="c", state=str(USER_ID), db=db)

    assert b"invalid or expired" in response.body
    assert db.added == []


@pytest.mark.asyncio
async def test_callback_accepts_valid_state_once(callback_env):
    state = create_state(USER_ID, SECRET)
    first_db, replay_db = _FakeDb(), _FakeDb()

    first = await oauth.google_callback(callback_env, code="c", state=state, db=first_db)
    replay = await oauth.google_callback(callback_env, code="c", state=state, db=replay_db)

    assert b"Connected" in first.body
    assert first_db.added[0].user_id == USER_ID
    assert first_db.committed
    assert b"invalid or expired" in replay.body
    assert replay_db.added == []


@pytest.mark.asyncio
async def test_callback_escapes_provider_error(callback_env):
    response = await oauth.google_callback(
        callback_env, error="<script>alert(1)</script>", db=_FakeDb()
    )

    assert b"<script>" not in response.body
