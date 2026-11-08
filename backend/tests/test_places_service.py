"""Places visited: stays from the phone, the conversations held there, deletes, cleanup."""

import uuid
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select

from app.core.timezone import local_day_bounds
from app.models.place_visit import PlaceVisit
from app.services import places
from tests.conftest import TEST_USER_ID

NOW = datetime(2026, 10, 24, 12, 0, tzinfo=timezone.utc)


def _visit(key="ios:1", arrived=NOW - timedelta(hours=2), minutes=60, **kwargs):
    left = kwargs.pop("left", arrived + timedelta(minutes=minutes) if minutes is not None else None)
    values = {
        "key": key,
        "arrived_at": arrived,
        "left_at": left,
        "latitude": 45.46,
        "longitude": 9.19,
        "accuracy_m": 30.0,
        "name": "Trattoria da Mario",
        "address": "Via Roma 12, Milano",
    }
    values.update(kwargs)
    return places.VisitIn(**values)


async def _all(db, user_id=TEST_USER_ID) -> list[PlaceVisit]:
    return list(await db.scalars(select(PlaceVisit).where(PlaceVisit.user_id == user_id)))


async def test_a_stay_is_kept_with_its_place(db_session):
    kept, dropped = await places.record_visits(
        db_session, TEST_USER_ID, [_visit()], source="ios", now=NOW
    )
    await db_session.commit()

    assert (kept, dropped) == (1, 0)
    [visit] = await _all(db_session)
    assert visit.name == "Trattoria da Mario" and visit.address == "Via Roma 12, Milano"
    assert visit.source == "ios" and visit.left_at == NOW - timedelta(hours=1)


async def test_the_same_key_updates_the_visit(db_session):
    # iOS says "arrived" first, then the whole stay; a retried batch sends it again
    await places.record_visits(
        db_session, TEST_USER_ID, [_visit(minutes=None, name=None)], source="ios", now=NOW
    )
    await places.record_visits(db_session, TEST_USER_ID, [_visit()], source="ios", now=NOW)
    await places.record_visits(db_session, TEST_USER_ID, [_visit()], source="ios", now=NOW)
    await db_session.commit()

    [visit] = await _all(db_session)
    assert visit.left_at is not None and visit.name == "Trattoria da Mario"


async def test_a_stay_closed_under_ten_minutes_is_dropped(db_session):
    await places.record_visits(
        db_session, TEST_USER_ID, [_visit(minutes=None)], source="android", now=NOW
    )
    kept, dropped = await places.record_visits(
        db_session, TEST_USER_ID, [_visit(minutes=6)], source="android", now=NOW
    )
    await db_session.commit()

    assert (kept, dropped) == (0, 1)
    assert await _all(db_session) == []


async def test_vague_old_and_impossible_stays_are_not_visits(db_session):
    visits = [
        _visit(key="a", accuracy_m=900.0),
        _visit(key="b", latitude=123.0),
        _visit(key="c", arrived=NOW - timedelta(days=91)),
        _visit(key="d", arrived=NOW + timedelta(hours=1)),
        _visit(key="e", arrived=NOW - timedelta(hours=1), left=NOW - timedelta(hours=2)),
        _visit(key="ok"),
    ]
    kept, dropped = await places.record_visits(
        db_session, TEST_USER_ID, visits, source="ios", now=NOW
    )
    await db_session.commit()

    assert (kept, dropped) == (1, 5)
    assert [v.key for v in await _all(db_session)] == ["ok"]


async def test_a_stay_still_going_counts_from_ten_minutes(db_session):
    await places.record_visits(
        db_session, TEST_USER_ID,
        [
            _visit(key="new", arrived=NOW - timedelta(minutes=4), minutes=None),
            _visit(key="settled", arrived=NOW - timedelta(minutes=40), minutes=None),
        ],
        source="android", now=NOW,
    )
    await db_session.commit()

    found = await places.visits_between(
        db_session, TEST_USER_ID, NOW - timedelta(hours=1), NOW, now=NOW
    )

    assert [v.key for v in found] == ["settled"]


async def test_the_place_of_a_conversation_is_the_visit_it_mostly_happened_in(db_session):
    await places.record_visits(
        db_session, TEST_USER_ID,
        [
            # 19:00–20:00 at home, 20:10–23:00 at the restaurant
            _visit(key="home", arrived=NOW.replace(hour=19), minutes=60, name="Home"),
            _visit(key="dinner", arrived=NOW.replace(hour=20, minute=10), minutes=170),
        ],
        source="ios", now=NOW + timedelta(days=1),
    )
    await db_session.commit()
    dinner, crossing, walking, short = (uuid.uuid4() for _ in range(4))
    spans = [
        # Mostly at the restaurant
        (dinner, NOW.replace(hour=19, minute=50), NOW.replace(hour=21)),
        # Half at home (10 of 20 minutes), the rest on the way: at home
        (crossing, NOW.replace(hour=19, minute=50), NOW.replace(hour=20, minute=10)),
        # 20:00–20:30, 20 minutes at the restaurant, 10 on the way: there
        (walking, NOW.replace(hour=20), NOW.replace(hour=20, minute=30)),
        # A few seconds, during the dinner
        (short, NOW.replace(hour=21), NOW.replace(hour=21)),
    ]

    found = await places.places_of(db_session, TEST_USER_ID, spans, now=NOW + timedelta(days=1))

    assert found[dinner].key == "dinner"
    assert found[crossing].key == "home"
    assert found[walking].key == "dinner"
    assert found[short].key == "dinner"


async def test_a_later_arrival_closes_a_stay_whose_departure_never_came(db_session):
    """iOS often sends the arrival and never the departure: the stay looked open until
    now, and a conversation hours later was placed there (28 bis rue Trachel)."""
    morning = NOW.replace(hour=8)
    await places.record_visits(
        db_session, TEST_USER_ID, [_visit(key="trachel", arrived=morning, minutes=None)],
        source="ios", now=NOW,
    )
    await places.record_visits(
        db_session, TEST_USER_ID,
        [_visit(key="pin", arrived=NOW.replace(hour=11), minutes=None, name="Place du Pin")],
        source="ios", now=NOW,
    )
    await db_session.commit()
    talk = uuid.uuid4()

    found = await places.places_of(
        db_session, TEST_USER_ID, [(talk, NOW - timedelta(minutes=20), NOW)], now=NOW
    )

    visits = {v.key: v for v in await _all(db_session)}
    assert visits["trachel"].left_at == NOW.replace(hour=11)
    assert visits["pin"].left_at is None
    assert found[talk].key == "pin"


async def test_a_conversation_mostly_on_the_way_has_no_place(db_session):
    await places.record_visits(
        db_session, TEST_USER_ID, [_visit(arrived=NOW.replace(hour=9), minutes=30)],
        source="ios", now=NOW,
    )
    await db_session.commit()
    talk = uuid.uuid4()

    # 9:20–10:00: 10 of its 40 minutes in the place
    found = await places.places_of(
        db_session, TEST_USER_ID, [(talk, NOW.replace(hour=9, minute=20), NOW.replace(hour=10))],
        now=NOW,
    )

    assert talk not in found


async def test_another_users_visits_are_not_theirs(db_session):
    other = uuid.uuid4()
    await places.record_visits(db_session, other, [_visit()], source="ios", now=NOW)
    await db_session.commit()

    assert await places.visits_between(db_session, TEST_USER_ID, NOW - timedelta(days=1), NOW,
                                       now=NOW) == []
    assert await places.delete_all(db_session, TEST_USER_ID) == 0
    assert len(await _all(db_session, other)) == 1


async def test_delete_one_a_day_and_all(db_session):
    day = date(2026, 10, 23)
    start, _ = local_day_bounds(day)
    await places.record_visits(
        db_session, TEST_USER_ID,
        [
            _visit(key="a", arrived=start + timedelta(hours=9)),
            _visit(key="b", arrived=start + timedelta(hours=15)),
            _visit(key="c", arrived=start + timedelta(days=1, hours=1)),
            _visit(key="d", arrived=start - timedelta(hours=3)),
        ],
        source="ios", now=NOW,
    )
    await db_session.commit()
    [first] = [v for v in await _all(db_session) if v.key == "d"]

    assert await places.delete_visit(db_session, TEST_USER_ID, first.id) is True
    assert await places.delete_visit(db_session, uuid.uuid4(), first.id) is False
    assert await places.delete_day(db_session, TEST_USER_ID, day) == 2
    assert [v.key for v in await _all(db_session)] == ["c"]
    assert await places.delete_all(db_session, TEST_USER_ID) == 1


async def test_visits_older_than_ninety_days_are_deleted(db_session):
    await places.record_visits(
        db_session, TEST_USER_ID,
        [_visit(key="old", arrived=NOW - timedelta(days=89, hours=23)), _visit(key="new")],
        source="ios", now=NOW,
    )
    await db_session.commit()

    deleted = await places.expire_visits(db_session, NOW + timedelta(days=1))

    assert deleted == 1
    assert [v.key for v in await _all(db_session)] == ["new"]


def test_a_place_is_called_by_its_name_else_its_address():
    named = PlaceVisit(name="Trattoria da Mario", address="Via Roma 12, Milano")
    street = PlaceVisit(name=None, address="Via Roma 12, Milano")
    nothing = PlaceVisit(name=None, address=None)

    assert places.label(named) == "Trattoria da Mario"
    assert places.label(street) == "Via Roma 12, Milano"
    assert places.label(nothing) is None
