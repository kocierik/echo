"""The few notifications worth sending: rules, promises, briefings, evening recap."""

from datetime import date, datetime, timedelta

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.provider import ToolResult
from app.core.timezone import user_zone
from app.models import Entity
from app.services import notifications as n
from app.services.entity_mentions import record_mentions
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation, make_entity

TODAY = date(2026, 10, 15)


def at(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=user_zone())


def notice(kind, when, key=None):
    return n.Notice(key or f"{kind}:{when}", kind, when, "t", "b", "today")


@pytest.fixture(autouse=True)
def no_calendar_cache():
    n._calendar_cache.clear()
    yield
    n._calendar_cache.clear()


def test_rules_quiet_hours_window_and_three_a_day_by_priority():
    now = at(TODAY, 7)
    notices = [
        notice("evening", at(TODAY, 21)),
        notice("promises", at(TODAY, 9)),
        notice("briefing", at(TODAY, 10)),
        notice("briefing", at(TODAY, 15)),
        notice("briefing", at(TODAY, 23)),  # quiet hours
        notice("briefing", at(TODAY, 6)),  # already past
        notice("promises", at(TODAY + timedelta(days=3), 9)),  # outside the window
    ]

    kept = n.select_notices(notices, now, now + timedelta(hours=36))

    # Briefings first, then the promises; the evening recap is the fourth: dropped
    assert [(k.kind, k.fire_at.hour) for k in kept] == [
        ("promises", 9),
        ("briefing", 10),
        ("briefing", 15),
    ]


def _promise(name, due=None, to=None, done=False) -> Entity:
    metadata = {"promise": True, "done": done}
    if due:
        metadata["due_date"] = due.isoformat()
    if to:
        metadata["promise_to"] = to
    return Entity(user_id=TEST_USER_ID, entity_type="task", name=name, metadata_=metadata)


def test_promises_one_morning_notice_per_day_none_without_a_date():
    promises = [
        _promise("Mandare il preventivo", TODAY, "Marco"),
        _promise("Richiamare Giulia", TODAY, "Giulia"),
        _promise("Portare il libro", TODAY + timedelta(days=1)),
        _promise("Prima o poi", None, "Ada"),
    ]

    notices = n.promise_notices(promises, TODAY, days=2)

    by_day = {x.fire_at.date(): x for x in notices}
    assert set(by_day) == {TODAY, TODAY + timedelta(days=1)}
    assert by_day[TODAY].title == "2 promises for today"
    assert "Mandare il preventivo (to Marco)" in by_day[TODAY].body
    assert by_day[TODAY].fire_at.hour == n.PROMISE_HOUR
    assert by_day[TODAY + timedelta(days=1)].body == "Portare il libro"


class FakeCalendar:
    def __init__(self, events, connected=("googlecalendar",)):
        self.events = events
        self.connected = list(connected)
        self.calls = 0

    async def connected_toolkits(self, user_id):
        return self.connected

    async def execute(self, user_id, tool, arguments):
        self.calls += 1
        assert tool == n.CALENDAR_TOOL and arguments["singleEvents"] is True
        return ToolResult(ok=True, data={"items": self.events})


def _event(summary, start, attendees=None, event_id="ev1"):
    return {
        "id": event_id,
        "summary": summary,
        "start": {"dateTime": start.isoformat()},
        "attendees": attendees,
    }


@pytest.mark.asyncio
async def test_a_briefing_only_when_there_is_something_to_know(db_session: AsyncSession):
    now = at(TODAY, 8)
    conversation, _ = await make_conversation(
        db_session, started_at=now - timedelta(days=2), title="Preventivo", texts=()
    )
    marco = make_entity(conversation, "person", "Marco Rossi")
    ada = make_entity(conversation, "person", "Ada", metadata={"email": "ada@x.it"})
    nobody = Entity(user_id=TEST_USER_ID, entity_type="person", name="Luca")
    promise = _promise("Mandare il preventivo", None, "Marco")
    db_session.add_all([marco, ada, nobody, promise])
    await db_session.flush()
    await record_mentions(db_session, [marco])
    await db_session.commit()
    calendar = FakeCalendar([
        _event("Call con Marco", at(TODAY, 11), event_id="m"),
        _event("Pranzo", at(TODAY, 13), [{"email": "ada@x.it"}, {"email": "me", "self": True}],
               event_id="a"),
        _event("Caffè con Luca", at(TODAY, 15), event_id="l"),  # nothing to know about Luca
        {"id": "allday", "summary": "Marco ferie", "start": {"date": TODAY.isoformat()}},
    ])

    notices = await n.upcoming_notices(
        db_session, TEST_USER_ID, now=now, provider=calendar, promises=False
    )

    # Ada is found by the guest's email; Luca has nothing to know about: no briefing
    assert [x.key for x in notices] == ["briefing:m", "briefing:a"]
    assert notices[1].target == f"person:{ada.id}"
    briefing = notices[0]
    assert briefing.fire_at == at(TODAY, 10, 50)
    assert briefing.title == "In 10 min: Call con Marco"
    assert briefing.body.startswith("Marco Rossi: you promised: Mandare il preventivo")
    assert "last talked" in briefing.body and "Preventivo" in briefing.body
    assert briefing.target == f"person:{marco.id}"

    # Asked again on the next wake: the calendar is not read again
    await n.upcoming_notices(db_session, TEST_USER_ID, now=now, provider=calendar)
    assert calendar.calls == 1


def test_people_are_found_by_name_or_invited_email():
    people = [
        Entity(name="Marco Rossi", entity_type="person", metadata_={}),
        Entity(name="Ada", entity_type="person", metadata_={"email": "ADA@x.it"}),
    ]
    event = {"summary": "Sync", "attendees": [{"email": "ada@x.it"}]}
    assert [p.name for p in n.people_in_event(event, people)] == ["Ada"]
    event = {"summary": "Riunione", "description": "con marco per il budget"}
    assert [p.name for p in n.people_in_event(event, people)] == ["Marco Rossi"]


@pytest.mark.asyncio
async def test_no_calendar_no_briefings(db_session: AsyncSession):
    calendar = FakeCalendar([_event("Call con Marco", at(TODAY, 11))], connected=["gmail"])
    notices = await n.upcoming_notices(
        db_session, TEST_USER_ID, now=at(TODAY, 8), provider=calendar
    )
    assert notices == [] and calendar.calls == 0


@pytest.mark.asyncio
async def test_the_evening_recap_only_when_asked_and_after_a_day_with_conversations(
    db_session: AsyncSession,
):
    now = at(TODAY, 18)
    assert await n.upcoming_notices(db_session, TEST_USER_ID, now=now, evening=True) == []

    conversation, _ = await make_conversation(db_session, started_at=at(TODAY, 10), texts=())
    task = make_entity(conversation, "task", "Comprare il pane")
    task.created_at = at(TODAY, 10)  # on the test's day, not the day the suite runs
    db_session.add(task)
    await db_session.commit()

    assert await n.upcoming_notices(db_session, TEST_USER_ID, now=now) == []  # off by default
    [recap] = await n.upcoming_notices(db_session, TEST_USER_ID, now=now, evening=True)
    assert recap.fire_at == at(TODAY, 21)
    assert recap.body == "1 conversation, 1 new task"


@pytest.mark.asyncio
async def test_the_endpoint_returns_what_to_schedule(client, auth_headers, db_session):
    tomorrow = datetime.now(user_zone()).date() + timedelta(days=1)
    db_session.add(_promise("Mandare il preventivo", tomorrow, "Marco"))
    await db_session.commit()

    response = await client.get("/api/notifications/upcoming", headers=auth_headers)

    [item] = response.json()["notifications"]
    assert item["kind"] == "promises" and item["target"] == "tasks"
    assert item["key"] == f"promises:{tomorrow.isoformat()}"
    off = await client.get("/api/notifications/upcoming?promises=false", headers=auth_headers)
    assert off.json()["notifications"] == []


def _phone_event(title, start, attendees=None, event_id="E1"):
    return n.phone_event(
        {"id": event_id, "title": title, "start": start, "attendees": attendees or []}
    )


@pytest.mark.asyncio
async def test_meetings_in_the_iphone_calendar_get_briefings_too(db_session: AsyncSession):
    now = at(TODAY, 8)
    conversation, _ = await make_conversation(
        db_session, started_at=now - timedelta(days=1), title="Preventivo", texts=()
    )
    marco = make_entity(conversation, "person", "Marco Rossi")
    db_session.add(marco)
    await db_session.commit()
    await record_mentions(db_session, [marco])
    await db_session.commit()

    notices = await n.upcoming_notices(
        db_session, TEST_USER_ID, now=now, promises=False,
        phone_events=[_phone_event("Call con Marco", at(TODAY, 11))],
    )

    [briefing] = notices
    assert briefing.key == "briefing:phone:E1"
    assert briefing.fire_at == at(TODAY, 10, 50)
    assert briefing.target == f"person:{marco.id}"


@pytest.mark.asyncio
async def test_a_meeting_in_both_calendars_is_briefed_once(db_session: AsyncSession):
    now = at(TODAY, 8)
    conversation, _ = await make_conversation(
        db_session, started_at=now - timedelta(days=1), title="Preventivo", texts=()
    )
    marco = make_entity(conversation, "person", "Marco Rossi")
    db_session.add(marco)
    await db_session.commit()
    await record_mentions(db_session, [marco])
    await db_session.commit()
    google = FakeCalendar([_event("Call con Marco", at(TODAY, 11), event_id="g1")])

    notices = await n.upcoming_notices(
        db_session, TEST_USER_ID, now=now, provider=google, promises=False,
        phone_events=[_phone_event("call con marco", at(TODAY, 11))],
    )

    assert [x.key for x in notices] == ["briefing:g1"]
    # The cached Google events are not changed by the iPhone's
    assert n._calendar_cache[str(TEST_USER_ID)][1] == google.events


def test_an_all_day_iphone_event_has_no_time_to_brief_before():
    event = n.phone_event({"id": "A", "title": "Ferie", "start": at(TODAY, 0), "all_day": True})
    assert event["start"] == {"date": TODAY.isoformat()}
    assert n._event_start(event) is None


@pytest.mark.asyncio
async def test_the_app_posts_the_iphone_events(client, auth_headers):
    tomorrow = datetime.now(user_zone()).replace(hour=11, minute=0, second=0, microsecond=0)
    tomorrow += timedelta(days=1)
    response = await client.post(
        "/api/notifications/upcoming",
        headers=auth_headers,
        json={
            "promises": False,
            "phone_events": [
                {"id": "E1", "title": "Call", "start": tomorrow.isoformat(), "attendees": []}
            ],
        },
    )
    # Nobody known is in the meeting: nothing to brief, but the events were read
    assert response.status_code == 200
    assert response.json() == {"notifications": []}
    too_many = await client.post(
        "/api/notifications/upcoming",
        headers=auth_headers,
        json={"phone_events": [{"id": str(i), "start": tomorrow.isoformat()} for i in range(301)]},
    )
    assert too_many.status_code == 422


@pytest.mark.asyncio
async def test_coming_up_recaps_the_last_talk_with_the_guest(db_session: AsyncSession):
    now = at(TODAY, 14, 20)
    conversation, _ = await make_conversation(
        db_session, started_at=now - timedelta(days=3), title="Il budget e la data di novembre",
        texts=(),
    )
    ada = make_entity(conversation, "person", "Ada")
    db_session.add(ada)
    await db_session.commit()
    await record_mentions(db_session, [ada])
    await db_session.commit()

    soon = await n.coming_up(
        db_session, TEST_USER_ID,
        [_phone_event("Later", at(TODAY, 15, 10), event_id="L"),
         _phone_event("Review with Ada", at(TODAY, 15))],
        now,
    )

    assert soon.title == "Review with Ada" and soon.start == at(TODAY, 15)
    assert soon.recap == "Last time: Il budget e la data di novembre"


@pytest.mark.asyncio
async def test_coming_up_ignores_events_after_an_hour_and_all_day(db_session: AsyncSession):
    now = at(TODAY, 14)
    events = [
        _phone_event("Too late", at(TODAY, 15, 30)),
        _phone_event("Already started", at(TODAY, 13, 50)),
        n.phone_event({"id": "D", "title": "Ferie", "start": at(TODAY, 0), "all_day": True}),
    ]

    assert await n.coming_up(db_session, TEST_USER_ID, events, now) is None
    assert await n.coming_up(db_session, TEST_USER_ID, [], now) is None


@pytest.mark.asyncio
async def test_coming_up_without_a_known_person_uses_the_title(db_session: AsyncSession):
    now = at(TODAY, 9)
    await make_conversation(
        db_session, started_at=now - timedelta(days=7), title="Atlas launch review", texts=()
    )
    await db_session.commit()

    soon = await n.coming_up(
        db_session, TEST_USER_ID, [_phone_event("Atlas", at(TODAY, 9, 30))], now
    )
    nothing = await n.coming_up(
        db_session, TEST_USER_ID, [_phone_event("Dentist", at(TODAY, 9, 30))], now
    )

    assert soon.recap == "Last time: Atlas launch review"
    assert nothing.title == "Dentist" and nothing.recap is None


@pytest.mark.asyncio
async def test_the_app_asks_what_is_coming_up(client, auth_headers):
    start = datetime.now(user_zone()) + timedelta(minutes=30)
    response = await client.post(
        "/api/notifications/coming-up",
        headers=auth_headers,
        json={"phone_events": [{"id": "E1", "title": "Call", "start": start.isoformat()}]},
    )
    empty = await client.post(
        "/api/notifications/coming-up", headers=auth_headers, json={"phone_events": []}
    )

    assert response.status_code == 200
    body = response.json()
    assert body["event"]["title"] == "Call" and body["recap"] is None
    assert empty.json() == {"event": None, "recap": None}


def _expected(name, due=None, sender=None, done=False) -> Entity:
    metadata = {"expected": True, "done": done}
    if due:
        metadata["due_date"] = due.isoformat()
    if sender:
        metadata["expected_from"] = sender
    return Entity(user_id=TEST_USER_ID, entity_type="task", name=name, metadata_=metadata)


def test_what_others_promised_is_asked_about_the_morning_after_it_was_due():
    waiting = [
        _expected("Preventivo da Marco", TODAY - timedelta(days=1), "Marco"),
        _expected("Foto della cena", TODAY - timedelta(days=1)),
        _expected("Contratto da Ada", TODAY + timedelta(days=1), "Ada"),
        _expected("Prima o poi", None, "Luca"),
    ]

    notices = n.waiting_notices(waiting, TODAY, days=2)

    by_day = {x.fire_at.date(): x for x in notices}
    # Due yesterday: today; due tomorrow: the day after; no date: never
    assert set(by_day) == {TODAY, TODAY + timedelta(days=2)}
    assert by_day[TODAY].title == "Still waiting for 2 things"
    assert "Marco: Preventivo da Marco" in by_day[TODAY].body
    assert by_day[TODAY + timedelta(days=2)].title == "Still waiting"
    assert by_day[TODAY].kind == "promises" and by_day[TODAY].target == "tasks"
    assert by_day[TODAY].fire_at.hour == n.PROMISE_HOUR


async def test_open_waiting_items_and_promises_stay_apart(db_session: AsyncSession):
    db_session.add_all([
        _expected("Preventivo da Marco", TODAY, "Marco"),
        _expected("Arrivato", TODAY, "Ada", done=True),
        _promise("Mandare le slide", TODAY, "Luca"),
    ])
    await db_session.commit()

    assert [e.name for e in await n.open_waiting(db_session, TEST_USER_ID)] == [
        "Preventivo da Marco"
    ]
    assert [e.name for e in await n.open_promises(db_session, TEST_USER_ID)] == [
        "Mandare le slide"
    ]


async def test_a_briefing_says_what_the_person_promised(db_session: AsyncSession):
    now = at(TODAY, 8)
    marco = Entity(user_id=TEST_USER_ID, entity_type="person", name="Marco Rossi")
    db_session.add_all([marco, _expected("Preventivo da Marco", None, "Marco")])
    await db_session.commit()
    calendar = FakeCalendar([_event("Call con Marco", at(TODAY, 11), event_id="m")])

    [briefing] = await n.upcoming_notices(
        db_session, TEST_USER_ID, now=now, provider=calendar, promises=False
    )

    # What Marco owes is said once: not counted again as an open task
    assert briefing.body == "Marco Rossi: they promised: Preventivo da Marco"


def test_notices_already_given_today_count_towards_three():
    now = at(TODAY, 7)
    tomorrow = TODAY + timedelta(days=1)
    notices = [
        notice("briefing", at(day, hour)) for day in (TODAY, tomorrow) for hour in (10, 12, 15)
    ]

    kept = n.select_notices(notices, now, now + timedelta(hours=48), taken={TODAY: 2})

    assert [(k.fire_at.date(), k.fire_at.hour) for k in kept] == [
        (TODAY, 10), (tomorrow, 10), (tomorrow, 12), (tomorrow, 15)
    ]
