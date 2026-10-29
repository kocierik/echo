"""What the security review of 29/10 closed: the operator's endpoints, the README's example
key, what /health tells, and CORS."""

import hashlib

from sqlalchemy import text

from app.core.config import Settings, settings
from tests.conftest import TEST_USER_ID
from tests.conftest import test_session as session_factory

EXAMPLE_KEY = "my-secret-key"


async def test_failed_jobs_are_not_for_any_user(client, auth_headers, monkeypatch):
    # Without an operator token the endpoints do not exist, even for a signed-in user
    monkeypatch.setattr(settings, "admin_token", "")
    assert (await client.get("/api/admin/dead-letter", headers=auth_headers)).status_code == 404
    assert (
        await client.post("/api/admin/dead-letter/retry", headers=auth_headers)
    ).status_code == 404

    monkeypatch.setattr(settings, "admin_token", "operator-token-0123456789")
    wrong = {**auth_headers, "X-Admin-Token": "operator-token-xxxxxxxxxx"}
    assert (await client.get("/api/admin/dead-letter", headers=wrong)).status_code == 403
    from app.main import app

    async def _empty(*_args):
        return []

    monkeypatch.setattr(app.state.redis, "lrange", _empty, raising=False)
    right = {"X-Admin-Token": "operator-token-0123456789"}
    response = await client.get("/api/admin/dead-letter", headers=right)
    assert response.status_code == 200
    assert response.json() == {"items": [], "count": 0}


async def test_the_readmes_example_key_never_opens_the_api(client):
    async with session_factory() as db:
        await db.execute(
            text(
                "INSERT INTO api_keys (user_id, key_hash, name) VALUES (:u, :h, 'example') "
                "ON CONFLICT (key_hash) DO NOTHING"
            ),
            {"u": str(TEST_USER_ID), "h": hashlib.sha256(EXAMPLE_KEY.encode()).hexdigest()},
        )
        await db.commit()

    response = await client.get("/api/stats", headers={"X-API-Key": EXAMPLE_KEY})

    assert response.status_code == 401


async def test_health_says_what_is_down_never_why(client, monkeypatch):
    import app.main as main

    class _Down:
        def connect(self):
            raise RuntimeError("could not connect to host db.internal:5432 as user echo")

    monkeypatch.setattr(main, "engine", _Down())

    body = (await client.get("/health")).json()

    assert body["postgres"] == "error"
    assert "db.internal" not in str(body)


def test_no_browser_origin_is_allowed_unless_configured():
    # The app and the connected apps are not browsers: CORS stays closed by default
    assert Settings.model_fields["cors_origins"].default == ""
