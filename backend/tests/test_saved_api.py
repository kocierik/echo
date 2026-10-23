"""The app's Saved page: the overview, a list, a thing and its moment, move, remove, the
late place; and the daily expiry."""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select

from app.models import Conversation, Photo
from app.models.saved import SavedItem
from app.services import saved
from app.workers import saved as saved_worker
from tests.conftest import TEST_USER_ID, test_session
from tests.factories import make_conversation

PLACE = {"latitude": 45.46, "longitude": 9.19, "accuracy_m": 10.0, "address": "Via Roma 12, Milano"}


async def _save(db, list_name, title, user_id=TEST_USER_ID, **kwargs):
    item, _ = await saved.save_item(
        db, user_id, list_name=list_name, title=title,
        moment=kwargs.pop("moment", saved.Moment(source="voice")), **kwargs,
    )
    await db.commit()
    return item


async def test_the_overview_has_places_first_then_lists_and_a_weeks_sum(
    client, auth_headers, db_session
):
    await _save(db_session, "La macchina", "Macchina", place=PLACE, latest_only=True, keep_days=7)
    for title in ("Barolo", "Vermentino"):
        await _save(db_session, "Vini", title)
    await _save(db_session, "Scontrini", "Esselunga", fields={"amount": "96,10"})
    await _save(db_session, "Scontrini", "Bar", fields={"amount": 3.2})
    old = await _save(db_session, "Scontrini", "Vecchio", fields={"amount": 50})
    old.created_at = datetime.now(timezone.utc) - timedelta(days=30)
    await db_session.commit()
    await _empty_list(db_session)
    await _save(db_session, "Altro", "x", user_id=uuid.uuid4())

    body = (await client.get("/api/saved", headers=auth_headers)).json()

    assert body["total"] == 6
    [car] = body["places"]
    assert car["title"] == "Macchina" and car["place"]["address"] == "Via Roma 12, Milano"
    assert car["latest_only"] is True and car["keep_days"] == 7
    lists = {lst["name"]: lst for lst in body["lists"]}
    # The car is its card; an empty list is not shown
    assert set(lists) == {"Vini", "Scontrini"}
    assert lists["Vini"]["count"] == 2 and len(lists["Vini"]["items"]) == 2
    assert lists["Vini"]["week_sum"] is None
    assert lists["Scontrini"]["week_sum"] == {"count": 2, "totals": {"EUR": 99.3}}
    assert body["latest_list"] in ("Scontrini", "La macchina")


async def _empty_list(db):
    item = await _save(db, "Vuota", "tmp")
    await saved.remove_item(db, item)
    await db.commit()


async def test_search_finds_by_words(client, auth_headers, db_session):
    await _save(db_session, "Libri", "Dune", details="Consigliato da Giulia")
    await _save(db_session, "Vini", "Barolo")

    body = (await client.get("/api/saved?q=giulia", headers=auth_headers)).json()

    assert [r["title"] for r in body["results"]] == ["Dune"]


async def test_a_list_and_every_list(client, auth_headers, db_session):
    first = await _save(db_session, "Vini", "Barolo")
    await _save(db_session, "Vini", "Etna")

    one = (await client.get(f"/api/saved/lists/{first.list_id}", headers=auth_headers)).json()
    every = (await client.get("/api/saved/lists", headers=auth_headers)).json()

    assert one["list"]["name"] == "Vini"
    assert [i["title"] for i in one["items"]] == ["Etna", "Barolo"]
    assert every == [
        {"id": str(first.list_id), "name": "Vini", "count": 2, "latest_only": False,
         "keep_days": None}
    ]


async def test_a_thing_and_its_moment(client, auth_headers, db_session):
    conversation, _ = await make_conversation(
        db_session, started_at=datetime.now(timezone.utc) - timedelta(hours=1), minutes=72,
        title="Cena con Marco",
    )
    photo = Photo(id=uuid.uuid4(), user_id=TEST_USER_ID, status="done", source="voice",
                  description="Barolo DOCG 2019, Cantina Rinaldi.")
    db_session.add(photo)
    await db_session.flush()
    item = await _save(
        db_session, "Vini", "Barolo 2019", details="Cantina Rinaldi", photo_id=photo.id,
        place=PLACE, people=[{"name": "Marco", "id": None}],
        moment=saved.Moment(request="Echo, salvami questo vino", source="voice",
                            conversation_id=conversation.id),
    )

    body = (await client.get(f"/api/saved/items/{item.id}", headers=auth_headers)).json()

    assert body["title"] == "Barolo 2019" and body["list"] == "Vini"
    assert body["photo_text"] == "Barolo DOCG 2019, Cantina Rinaldi."
    moment = body["moment"]
    assert moment["request"] == "Echo, salvami questo vino"
    assert moment["people"] == [{"name": "Marco", "id": None}]
    assert moment["conversation"]["title"] == "Cena con Marco"
    assert moment["conversation"]["duration_s"] == 72 * 60

    # The conversation and the photo deleted: the thing stays, with its text
    await db_session.execute(delete(Conversation).where(Conversation.id == conversation.id))
    await db_session.execute(delete(Photo).where(Photo.id == photo.id))
    await db_session.commit()
    after = (await client.get(f"/api/saved/items/{item.id}", headers=auth_headers)).json()
    assert after["moment"]["conversation"] is None and after["photo_id"] is None
    assert after["photo_text"] is None and after["details"] == "Cantina Rinaldi"


async def test_a_voice_things_conversation_comes_from_its_segment(
    client, auth_headers, db_session
):
    conversation, _ = await make_conversation(
        db_session, started_at=datetime.now(timezone.utc), title="In macchina",
    )
    from app.models import Segment

    segment = (await db_session.scalars(
        select(Segment).where(Segment.conversation_id == conversation.id)
    )).first()
    item = await _save(
        db_session, "La macchina", "Macchina",
        moment=saved.Moment(source="voice", segment_id=segment.id),
    )

    body = (await client.get(f"/api/saved/items/{item.id}", headers=auth_headers)).json()

    assert body["moment"]["conversation"]["title"] == "In macchina"


async def test_move_remove_and_the_late_place(client, auth_headers, db_session):
    item = await _save(db_session, "Vini", "Dune")

    moved = await client.patch(
        f"/api/saved/items/{item.id}", headers=auth_headers, json={"list": "Libri"}
    )
    placed = await client.put(
        f"/api/saved/items/{item.id}/place", headers=auth_headers, json=PLACE
    )
    bad = await client.put(
        f"/api/saved/items/{item.id}/place", headers=auth_headers,
        json={"latitude": 200, "longitude": 0},
    )
    removed = await client.delete(f"/api/saved/items/{item.id}", headers=auth_headers)

    assert moved.status_code == 200 and moved.json()["list"] == "Libri"
    assert placed.json()["place"]["address"] == "Via Roma 12, Milano"
    assert bad.status_code == 422
    assert removed.status_code == 204
    async with test_session() as db:
        assert (await db.scalars(select(SavedItem))).all() == []


async def test_another_users_thing_is_not_found(client, auth_headers, db_session):
    item = await _save(db_session, "Vini", "Barolo", user_id=uuid.uuid4())

    for response in (
        await client.get(f"/api/saved/items/{item.id}", headers=auth_headers),
        await client.get(f"/api/saved/lists/{item.list_id}", headers=auth_headers),
        await client.delete(f"/api/saved/items/{item.id}", headers=auth_headers),
        await client.patch(f"/api/saved/items/{item.id}", headers=auth_headers,
                           json={"list": "Mia"}),
    ):
        assert response.status_code == 404


async def test_the_daily_job_deletes_expired_things(db_session):
    car = await _save(db_session, "La macchina", "Macchina", latest_only=True, keep_days=7)
    car.created_at = datetime.now(timezone.utc) - timedelta(days=8)
    await db_session.commit()

    assert await saved_worker.expire_saved_things(session_factory=test_session) == 1
    async with test_session() as db:
        assert (await db.scalars(select(SavedItem))).all() == []
