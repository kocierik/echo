"""GET /api/plan: the account's plan and this month's speech, for Profile → Plan and Today."""

import uuid
from datetime import datetime, timezone

from app.models.llm_usage import LlmUsage
from app.models.segment import Segment
from app.models.user import User
from app.services.plans import next_month_start
from tests.conftest import TEST_USER_ID


async def test_the_plan_and_its_use(client, auth_headers, db_session):
    today = datetime.now(timezone.utc).date()
    db_session.add(User(id=TEST_USER_ID, email="erik@example.com", password_hash="x", plan="plus"))
    db_session.add(LlmUsage(
        id=uuid.uuid4(), user_id=TEST_USER_ID, day=today, kind="stt", model="m", calls=3,
        input_units=4000,
    ))
    now = datetime.now(timezone.utc)
    db_session.add(Segment(
        id=uuid.uuid4(), user_id=TEST_USER_ID, received_at=now, recorded_at=now,
        duration_ms=90_000, audio_path="/data/audio/x.adpcm", transcription_status="deferred",
    ))
    await db_session.commit()

    response = await client.get("/api/plan", headers=auth_headers)

    assert response.status_code == 200
    assert response.json() == {
        "plan": "plus",
        "monthly_seconds": 1500 * 60,
        "used_seconds": 4000,
        "daily_seconds": 600,
        "deferred_seconds": 90,
        "resets_on": next_month_start(today).isoformat(),
        "over_budget": False,
        "web_searches_per_day": 30,
        "routines": 10,
    }


async def test_a_key_without_account_is_free(client, auth_headers):
    body = (await client.get("/api/plan", headers=auth_headers)).json()

    assert body["plan"] == "free"
    assert body["monthly_seconds"] == 300 * 60
    assert body["used_seconds"] == 0 and body["over_budget"] is False


async def test_needs_a_key(client):
    assert (await client.get("/api/plan")).status_code == 403  # as every REST route
