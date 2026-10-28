"""GET, PATCH and DELETE /api/routines: the user's routines, paused, resumed or removed.
Routines are created by asking Echo, never here."""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.models.routine import Routine
from tests.conftest import TEST_USER_ID, test_session


async def _routine(user_id=TEST_USER_ID, **values) -> Routine:
    routine = Routine(
        id=uuid.uuid4(),
        user_id=user_id,
        instruction=values.get("instruction", "dimmi che tempo fa a Milano"),
        schedule=values.get("schedule", {"kind": "daily", "time": "07:00"}),
        timezone="Europe/Rome",
        active=values.get("active", True),
        next_run_at=values.get("next_run_at", datetime.now(timezone.utc) + timedelta(hours=3)),
        source="voice",
        created_at=values.get("created_at", datetime.now(timezone.utc)),
        mode=values.get("mode", "always"),
    )
    async with test_session() as db:
        db.add(routine)
        await db.commit()
    return routine


async def test_the_list_is_the_users_own_newest_first(client, auth_headers):
    old = await _routine(created_at=datetime.now(timezone.utc) - timedelta(days=2))
    new = await _routine(
        instruction="riassumi le email", schedule={"kind": "weekdays", "time": "08:30"}
    )
    await _routine(user_id=uuid.uuid4())

    response = await client.get("/api/routines", headers=auth_headers)

    assert response.status_code == 200
    body = response.json()
    assert [r["id"] for r in body] == [str(new.id), str(old.id)]
    assert body[0]["schedule_text"] == "Weekdays at 08:30"
    assert body[0]["instruction"] == "riassumi le email"
    assert body[0]["active"] is True and body[0]["last_status"] is None


async def test_pausing_and_resuming_recompute_the_next_run(client, auth_headers):
    stale = datetime.now(timezone.utc) - timedelta(days=3)
    routine = await _routine(next_run_at=stale)

    paused = await client.patch(
        f"/api/routines/{routine.id}", headers=auth_headers, json={"active": False}
    )
    assert paused.status_code == 200
    assert paused.json()["active"] is False

    resumed = await client.patch(
        f"/api/routines/{routine.id}", headers=auth_headers, json={"active": True}
    )
    next_run = datetime.fromisoformat(resumed.json()["next_run_at"])
    # From now, not the stale time: it does not run at once for the days it was paused
    assert datetime.now(timezone.utc) < next_run <= datetime.now(timezone.utc) + timedelta(days=1)


async def test_delete(client, auth_headers):
    routine = await _routine()

    response = await client.delete(f"/api/routines/{routine.id}", headers=auth_headers)

    assert response.status_code == 204
    async with test_session() as db:
        assert (await db.scalars(select(Routine))).all() == []


async def test_another_users_routine_is_not_found(client, auth_headers):
    routine = await _routine(user_id=uuid.uuid4())

    patch = await client.patch(
        f"/api/routines/{routine.id}", headers=auth_headers, json={"active": False}
    )
    delete = await client.delete(f"/api/routines/{routine.id}", headers=auth_headers)

    assert patch.status_code == 404 and delete.status_code == 404


async def test_the_routines_list_has_each_mode(client, auth_headers):
    await _routine(mode="only_new")

    response = await client.get("/api/routines", headers=auth_headers)

    assert response.json()[0]["mode"] == "only_new"
