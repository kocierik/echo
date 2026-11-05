"""Profile → Health: Apple's Shortcuts sends a day of the Health app with a key that can
do nothing else; what it sends is read leniently (the phone's locale, sleep in hours,
minutes or seconds) and goes into every answer's prompt."""

from datetime import date

import pytest

from app.services import health
from app.services.personal import personal_context
from tests.conftest import TEST_USER_ID, test_session


@pytest.mark.parametrize(
    ("value", "minutes"),
    [(6.8, 408), ("6,5", 390), (410, 410), (24600, 410), ("6:50", 410), ("7 h 15 m", 435),
     ("ore 7", 420), (None, None), ("niente", None)],
)
def test_sleep_in_hours_minutes_seconds_or_words(value, minutes):
    assert health.sleep_minutes(value) == minutes


def test_numbers_as_an_italian_iphone_writes_them():
    day = health.read_day(
        {"date": "2026-11-04", "steps": "8.421", "distance": "5,1", "active_kcal": "1.234",
         "exercise_minutes": 32, "workouts": ["Corsa 32 min", ""]},
        date(2026, 11, 5),
    )

    assert day["day"] == date(2026, 11, 4)
    assert (day["steps"], day["distance_km"], day["active_kcal"]) == (8421, 5.1, 1234)
    assert day["workouts"] == "Corsa 32 min"
    # Metres, when it cannot be kilometres
    assert health.distance_km(5100) == 5.1
    # No date: the user's today
    assert health.read_day({}, date(2026, 11, 5))["day"] == date(2026, 11, 5)


async def _shortcut_key(client, auth_headers):
    response = await client.post("/api/health/key", headers=auth_headers)
    assert response.status_code == 200
    assert response.json()["path"] == "/api/health/day"
    return {"X-API-Key": response.json()["api_key"]}


async def test_the_shortcut_sends_a_day_and_sees_what_was_understood(client, auth_headers):
    key = await _shortcut_key(client, auth_headers)

    response = await client.post(
        "/api/health/day", headers=key,
        json={"date": "2026-11-04", "sleep": "6,8", "steps": "8.421"},
    )

    assert response.status_code == 200
    assert (response.json()["sleep_minutes"], response.json()["steps"]) == (408, 8421)
    # Sent again with more: what it carries changes, the rest stays
    await client.post("/api/health/day", headers=key, json={"date": "2026-11-04", "steps": 9000})
    async with test_session() as db:
        [day] = await health.recent_days(db, TEST_USER_ID, days=10_000)
    assert (day.sleep_minutes, day.steps) == (408, 9000)


async def test_the_shortcut_key_can_do_nothing_else(client, auth_headers):
    key = await _shortcut_key(client, auth_headers)

    for path in ("/api/conversations", "/api/health/days", "/api/facts"):
        response = await client.get(path, headers=key)
        assert response.status_code == 403, path
        assert "only sends health data" in response.json()["detail"]


async def test_a_new_key_ends_the_old_one(client, auth_headers):
    old = await _shortcut_key(client, auth_headers)
    await _shortcut_key(client, auth_headers)

    response = await client.post("/api/health/day", headers=old, json={"steps": 1})

    assert response.status_code == 401


async def test_the_days_go_into_every_answer(client, auth_headers):
    key = await _shortcut_key(client, auth_headers)
    today = health.today().isoformat()
    await client.post(
        "/api/health/day", headers=key,
        json={"date": today, "sleep": 6.5, "steps": 8000, "workouts": "Corsa 30 min"},
    )

    days = (await client.get("/api/health/days", headers=auth_headers)).json()["days"]
    async with test_session() as db:
        prompt = await personal_context(db, TEST_USER_ID)

    assert days[0]["steps"] == 8000
    assert "Health app" in prompt
    assert f"{today}: slept 6 h 30 min, 8000 steps" in prompt
    assert "Corsa 30 min" in prompt


async def test_forgetting_deletes_the_days_and_the_key(client, auth_headers):
    key = await _shortcut_key(client, auth_headers)
    await client.post("/api/health/day", headers=key, json={"steps": 100})

    response = await client.delete("/api/health", headers=auth_headers)

    assert response.status_code == 204
    assert (await client.get("/api/health/days", headers=auth_headers)).json()["days"] == []
    assert (await client.post("/api/health/day", headers=key, json={})).status_code == 401
