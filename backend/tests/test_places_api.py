"""The places API: the phone's batched stays, the list by day, the deletes; conversations
with their place (never to outside assistants); the 90-day cleanup."""

import json
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.core.timezone import to_user_local_date
from app.models.place_visit import PlaceVisit
from app.services import places
from app.workers import places as places_worker
from tests.conftest import TEST_USER_ID, test_session
from tests.factories import make_conversation
from tests.test_mcp_tools import _key, call

NOW = datetime.now(timezone.utc).replace(microsecond=0)


def _stay(key, arrived, minutes=90, **kwargs):
    body = {
        "key": key,
        "arrived_at": arrived.isoformat(),
        "left_at": (arrived + timedelta(minutes=minutes)).isoformat() if minutes else None,
        "latitude": 45.46,
        "longitude": 9.19,
        "accuracy_m": 25,
        "name": "Trattoria da Mario",
        "address": "Via Roma 12, Milano",
    }
    body.update(kwargs)
    return body


async def _post(client, auth_headers, *stays, source="ios"):
    response = await client.post(
        "/api/places/visits", headers=auth_headers,
        json={"source": source, "visits": list(stays)},
    )
    assert response.status_code == 200, response.text
    return response.json()


async def test_the_phone_sends_its_stays_in_a_batch(client, auth_headers, db_session):
    body = await _post(
        client, auth_headers,
        _stay("ios:1", NOW - timedelta(hours=5)),
        _stay("ios:2", NOW - timedelta(hours=2), minutes=5),
        _stay("ios:3", NOW - timedelta(minutes=30), minutes=None),
    )

    assert body == {"kept": 2, "dropped": 1}
    keys = {v.key for v in await db_session.scalars(select(PlaceVisit))}
    assert keys == {"ios:1", "ios:3"}


async def test_a_bad_batch_is_refused(client, auth_headers):
    too_many = [_stay(f"k{i}", NOW - timedelta(hours=3)) for i in range(201)]
    for body in (
        {"source": "ios", "visits": too_many},
        {"source": "windows", "visits": []},
        {"source": "ios", "visits": [{"key": "x"}]},
    ):
        response = await client.post("/api/places/visits", headers=auth_headers, json=body)
        assert response.status_code == 422


async def test_the_visits_newest_first_with_their_conversations(client, auth_headers, db_session):
    dinner_at = NOW - timedelta(hours=3)
    conversation, _ = await make_conversation(
        db_session, started_at=dinner_at + timedelta(minutes=10), minutes=40,
        title="Cena con Marco",
    )
    await db_session.commit()
    await _post(
        client, auth_headers,
        _stay("a", NOW - timedelta(days=1)),
        _stay("b", dinner_at),
    )

    body = (await client.get("/api/places/visits", headers=auth_headers)).json()

    assert [v["name"] for v in body["visits"]] == ["Trattoria da Mario"] * 2
    first, second = body["visits"]
    assert first["arrived_at"] > second["arrived_at"]
    assert first["conversations"] == [{"id": str(conversation.id), "title": "Cena con Marco"}]
    assert second["conversations"] == []
    assert body["more"] is False


async def test_the_visits_come_a_page_at_a_time(client, auth_headers):
    await _post(client, auth_headers, *[
        _stay(f"k{i}", NOW - timedelta(hours=3 * (i + 1)), minutes=60) for i in range(5)
    ])

    page = (await client.get("/api/places/visits?limit=3", headers=auth_headers)).json()
    before = page["visits"][-1]["arrived_at"]
    rest = (
        await client.get(
            "/api/places/visits", headers=auth_headers, params={"limit": 3, "before": before}
        )
    ).json()

    assert len(page["visits"]) == 3 and page["more"] is True
    assert len(rest["visits"]) == 2 and rest["more"] is False


async def test_delete_one_a_day_and_all(client, auth_headers, db_session):
    other = uuid.uuid4()
    await places.record_visits(
        db_session, other, [places.VisitIn("x", NOW - timedelta(hours=3), NOW, 45.0, 9.0)],
        source="ios", now=NOW,
    )
    await db_session.commit()
    yesterday = NOW - timedelta(days=1)
    await _post(
        client, auth_headers,
        _stay("a", NOW - timedelta(days=3)),
        _stay("b", yesterday),
        _stay("c", yesterday + timedelta(minutes=95)),
    )
    visits = (await client.get("/api/places/visits", headers=auth_headers)).json()["visits"]
    theirs = (await db_session.scalars(select(PlaceVisit).where(PlaceVisit.key == "x"))).one()

    oldest = visits[-1]["id"]
    assert (await client.delete(f"/api/places/visits/{oldest}", headers=auth_headers)
            ).status_code == 204
    assert (await client.delete(f"/api/places/visits/{theirs.id}", headers=auth_headers)
            ).status_code == 404
    day = to_user_local_date(yesterday + timedelta(minutes=95)).isoformat()
    deleted_day = (await client.delete(f"/api/places/days/{day}", headers=auth_headers)).json()
    left = (await client.get("/api/places/visits", headers=auth_headers)).json()["visits"]
    deleted_all = (await client.delete("/api/places/visits", headers=auth_headers)).json()

    assert deleted_day["deleted"] >= 1
    assert deleted_day["deleted"] + len(left) == 2
    assert deleted_all == {"deleted": len(left)}
    async with test_session() as fresh:
        remaining = list(await fresh.scalars(select(PlaceVisit)))
    assert [v.key for v in remaining] == ["x"]


async def test_conversations_carry_their_place(client, auth_headers, db_session):
    arrived = NOW - timedelta(hours=4)
    there, _ = await make_conversation(
        db_session, started_at=arrived + timedelta(minutes=20), minutes=30, title="Cena con Marco"
    )
    elsewhere, _ = await make_conversation(
        db_session, started_at=NOW - timedelta(days=2), minutes=30, title="Altro"
    )
    await db_session.commit()
    await _post(client, auth_headers, _stay("dinner", arrived, minutes=120))

    listed = (await client.get("/api/conversations", headers=auth_headers)).json()
    detail = (await client.get(f"/api/conversations/{there.id}", headers=auth_headers)).json()

    by_title = {c["title"]: c for c in listed["conversations"]}
    assert by_title["Cena con Marco"]["place"]["name"] == "Trattoria da Mario"
    assert by_title["Cena con Marco"]["place"]["address"] == "Via Roma 12, Milano"
    assert by_title["Altro"]["place"] is None
    assert detail["place"]["name"] == "Trattoria da Mario"
    assert elsewhere.id


async def test_outside_assistants_get_no_place(client, auth_headers, db_session):
    arrived = NOW - timedelta(hours=4)
    conversation, _ = await make_conversation(
        db_session, started_at=arrived + timedelta(minutes=20), minutes=30
    )
    await db_session.commit()
    await _post(client, auth_headers, _stay("dinner", arrived, minutes=120))
    key = await _key(client, auth_headers)

    one = await call(client, key, "get_conversation", {"conversation_id": str(conversation.id)})
    day = await call(
        client, key, "get_day", {"date": to_user_local_date(conversation.started_at).isoformat()}
    )

    for result in (one, day):
        text = json.dumps(result)
        assert "Mario" not in text and "Via Roma" not in text


async def test_the_cleanup_deletes_visits_after_ninety_days(db_session):
    await places.record_visits(
        db_session, TEST_USER_ID,
        [
            places.VisitIn("old", NOW - timedelta(days=89, hours=23), NOW - timedelta(days=89),
                           45.0, 9.0),
            places.VisitIn("new", NOW - timedelta(hours=3), NOW - timedelta(hours=2), 45.0, 9.0),
        ],
        source="android", now=NOW,
    )
    await db_session.commit()

    deleted = await places_worker.expire_old_visits(
        NOW + timedelta(days=1), session_factory=test_session
    )

    assert deleted == 1
