"""What the phone was given each day: scheduled notices, briefs sent at once, the switch."""

from datetime import date, datetime, timedelta

from app.core.timezone import user_zone
from app.services import notice_ledger as ledger
from app.services.notifications import Notice
from tests.conftest import TEST_USER_ID
from tests.fakes.redis import InMemoryRedis

TODAY = date(2026, 10, 15)


def at(hour: int, minute: int = 0, day: date = TODAY) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=user_zone())


def notice(key, when, kind="briefing", target="person:p1"):
    return Notice(key, kind, when, "t", "b", target)


async def test_refresh_replaces_future_entries():
    redis = InMemoryRedis()
    until = at(8) + timedelta(hours=36)
    await ledger.record_scheduled(
        redis, TEST_USER_ID, [notice("a", at(9)), notice("b", at(15))], at(8), until
    )
    assert await ledger.count_on(redis, TEST_USER_ID, TODAY) == 2

    # At 10 the 9 o'clock one has fired; the 15 o'clock one is no longer handed out
    later = at(10)
    await ledger.record_scheduled(
        redis, TEST_USER_ID, [notice("c", at(18))], later, later + timedelta(hours=36)
    )
    await ledger.record_scheduled(
        redis, TEST_USER_ID, [notice("c", at(18))], later, later + timedelta(hours=36)
    )
    assert await ledger.count_on(redis, TEST_USER_ID, TODAY) == 2  # a (fired) and c, once

    await ledger.record_sent(redis, TEST_USER_ID, "person:p2:x", "person", "person:p2", later)
    assert await ledger.count_on(redis, TEST_USER_ID, TODAY) == 3
    # Given already (fired or sent at once): what the next refresh counts as taken
    assert await ledger.given_per_day(redis, TEST_USER_ID, later, later + timedelta(hours=36)) == {
        TODAY: 2
    }


async def test_briefing_near_looks_an_hour_either_side():
    redis = InMemoryRedis()
    await ledger.record_scheduled(
        redis,
        TEST_USER_ID,
        [notice("m", at(10, 50)), notice("p", at(9), kind="promises", target="tasks")],
        at(8),
        at(8) + timedelta(hours=36),
    )
    hour = timedelta(hours=1)

    assert await ledger.briefing_near(redis, TEST_USER_ID, "person:p1", at(10), hour)
    assert await ledger.briefing_near(redis, TEST_USER_ID, "person:p1", at(11, 40), hour)
    assert not await ledger.briefing_near(redis, TEST_USER_ID, "person:p1", at(12), hour)
    assert not await ledger.briefing_near(redis, TEST_USER_ID, "person:p2", at(10), hour)
    assert not await ledger.briefing_near(redis, TEST_USER_ID, "tasks", at(9), hour)


async def test_briefings_switch_is_remembered():
    redis = InMemoryRedis()
    assert await ledger.briefings_on(redis, TEST_USER_ID)
    await ledger.set_briefings(redis, TEST_USER_ID, False)
    assert not await ledger.briefings_on(redis, TEST_USER_ID)
    await ledger.set_briefings(redis, TEST_USER_ID, True)
    assert await ledger.briefings_on(redis, TEST_USER_ID)
