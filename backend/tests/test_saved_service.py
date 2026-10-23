"""Saved: one generic thing in a list Echo makes, saved, updated, found, summed, expired."""

import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import delete, select

from app.models.entity import Entity
from app.models.photo import Photo
from app.models.saved import SavedItem, SavedList
from app.services import saved
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService

VOICE = saved.Moment(request="Echo, salvami questo vino", source="voice")
PLACE = {"latitude": 45.46, "longitude": 9.19, "accuracy_m": 12.0, "address": "Via Roma 12, Milano"}


async def _items(db) -> list[SavedItem]:
    return list(await db.scalars(select(SavedItem).where(SavedItem.user_id == TEST_USER_ID)))


async def test_saving_starts_the_list_and_keeps_the_moment(db_session):
    item, created = await saved.save_item(
        db_session, TEST_USER_ID, list_name="Vini", title="Barolo 2019",
        details="Cantina Rinaldi", fields={"vintage": "2019"}, moment=VOICE,
        embedding_service=MockEmbeddingService(),
    )
    await db_session.commit()

    assert created
    assert item.list.name == "Vini" and not item.list.latest_only
    assert item.request_text == "Echo, salvami questo vino" and item.source == "voice"
    assert item.fields == {"vintage": "2019"}
    assert item.embedding is not None


async def test_the_same_title_in_the_same_list_is_updated_not_duplicated(db_session):
    await saved.save_item(
        db_session, TEST_USER_ID, list_name="Dove sono le cose", title="Passaporto",
        details="Nell'armadio", moment=VOICE,
    )
    item, created = await saved.save_item(
        db_session, TEST_USER_ID, list_name="dove sono le cose ", title="passaporto",
        details="Nel cassetto della scrivania", moment=VOICE,
    )

    assert not created
    [only] = await _items(db_session)
    assert only.id == item.id and only.details == "Nel cassetto della scrivania"
    assert len(list(await db_session.scalars(select(SavedList)))) == 1


async def test_a_latest_only_list_keeps_only_its_latest_thing(db_session):
    first, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="La macchina", title="Macchina", place=PLACE,
        latest_only=True, keep_days=7, moment=VOICE,
    )
    second, created = await saved.save_item(
        db_session, TEST_USER_ID, list_name="La macchina", title="Auto in Via Verdi",
        moment=VOICE,
    )

    assert created
    [only] = await _items(db_session)
    assert only.id == second.id
    assert only.list.latest_only and only.list.keep_days == 7


async def test_update_keeps_the_place(db_session):
    car, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="La macchina", title="Macchina", place=PLACE,
        latest_only=True, keep_days=7, moment=VOICE,
    )
    photo = Photo(id=uuid.uuid4(), user_id=TEST_USER_ID, status="done", source="voice")
    db_session.add(photo)
    await db_session.flush()

    await saved.update_item(
        db_session, car, fields={"level": "-2", "column": "B4"}, photo_id=photo.id
    )

    assert car.place == PLACE and car.photo_id == photo.id
    assert car.fields == {"level": "-2", "column": "B4"}


async def test_update_merges_fields_removes_with_none_and_moves(db_session):
    item, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="Spese", title="Esselunga",
        fields={"amount": 12.5, "note": "x"}, moment=VOICE,
    )

    await saved.update_item(
        db_session, item, fields={"note": None, "shop": "Esselunga"}, list_name="Scontrini"
    )

    assert item.fields == {"amount": 12.5, "shop": "Esselunga"}
    assert item.list.name == "Scontrini"


async def test_people_are_matched_to_people(db_session):
    db_session.add(Entity(user_id=TEST_USER_ID, entity_type="person", name="Marco Rossi"))
    await db_session.flush()

    people = await saved.match_people(db_session, TEST_USER_ID, ["Marco", "Giulia"])

    assert people[0]["name"] == "Marco Rossi" and people[0]["id"] is not None
    assert people[1] == {"name": "Giulia", "id": None}


async def test_find_by_words_list_and_period(db_session):
    old, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="Libri", title="Dune",
        details="Consigliato da Giulia", moment=VOICE,
    )
    old.created_at = datetime.now(timezone.utc) - timedelta(days=40)
    await saved.save_item(
        db_session, TEST_USER_ID, list_name="Vini", title="Vermentino", moment=VOICE,
    )
    await db_session.flush()

    assert [i.title for i in await saved.find_items(db_session, TEST_USER_ID, query="Giulia")] == [
        "Dune"
    ]
    in_list = await saved.find_items(db_session, TEST_USER_ID, list_name="vini")
    assert [i.title for i in in_list] == ["Vermentino"]
    recent = await saved.find_items(
        db_session, TEST_USER_ID, date_from=datetime.now(timezone.utc) - timedelta(days=7)
    )
    assert [i.title for i in recent] == ["Vermentino"]
    # A word of the list's name finds its things
    assert [i.title for i in await saved.find_items(db_session, TEST_USER_ID, query="libri")] == [
        "Dune"
    ]


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (12.5, (Decimal("12.5"), None)),
        ("12,50", (Decimal("12.50"), None)),
        ("€ 7.90", (Decimal("7.90"), "EUR")),
        ("1.234,50 €", (Decimal("1234.50"), "EUR")),
        ("$3", (Decimal("3"), "USD")),
        ("tanto", (None, None)),
    ],
)
def test_amounts_are_read_from_numbers_and_text(value, expected):
    assert saved.parse_amount(value) == expected


async def test_sum_reads_text_amounts_per_currency(db_session):
    for title, fields in (
        ("Esselunga", {"amount": "96,10"}),
        ("Bar", {"amount": 3.2, "currency": "EUR"}),
        ("Taxi NY", {"amount": "$20"}),
        ("Senza importo", {}),
    ):
        await saved.save_item(
            db_session, TEST_USER_ID, list_name="Scontrini", title=title, fields=fields,
            moment=VOICE,
        )

    total = await saved.sum_items(db_session, TEST_USER_ID, list_name="scontrini")

    assert total == {
        "list": "Scontrini", "count": 3, "totals": {"EUR": 99.3, "USD": 20.0},
    }


async def test_things_past_their_lists_days_expire(db_session):
    car, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="La macchina", title="Macchina",
        latest_only=True, keep_days=7, moment=VOICE,
    )
    wine, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="Vini", title="Barolo", moment=VOICE,
    )
    old = datetime.now(timezone.utc) - timedelta(days=8)
    car.created_at = wine.created_at = old
    await db_session.commit()

    assert await saved.expire_items(db_session, datetime.now(timezone.utc)) == 1
    assert [i.title for i in await _items(db_session)] == ["Barolo"]
    # The list stays, with its settings, for the next parking
    assert (await saved.find_list(db_session, TEST_USER_ID, "La macchina")).latest_only


async def test_deleting_the_photo_keeps_the_thing(db_session):
    photo = Photo(id=uuid.uuid4(), user_id=TEST_USER_ID, status="done", source="voice")
    db_session.add(photo)
    await db_session.flush()
    item, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="Vini", title="Barolo", photo_id=photo.id,
        moment=VOICE,
    )
    await db_session.commit()

    await db_session.execute(delete(Photo).where(Photo.id == photo.id))
    await db_session.commit()
    await db_session.refresh(item)

    assert item.photo_id is None and item.title == "Barolo"


async def test_without_places_nothing_says_where(db_session):
    car, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="La macchina", title="Macchina", place=PLACE,
        people=[{"name": "Marco", "id": None}], moment=VOICE,
    )

    full = saved.describe_item(car)
    hidden = saved.describe_item(car, include_place=False)

    assert full["address"] == "Via Roma 12, Milano"
    assert "address" not in hidden and "45.46" not in str(hidden)
    assert "Via Roma" in saved.item_line(car)
    assert "Via Roma" not in saved.item_line(car, include_place=False)
    assert "Marco" in saved.item_line(car)
