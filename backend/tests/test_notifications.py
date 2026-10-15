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
    db_session.add(make_entity(conversation, "task", "Comprare il pane"))
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
