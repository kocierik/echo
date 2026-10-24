"""Plans: each account's monthly speech budget, read from what transcription recorded in
`llm_usage` this calendar month (UTC), and the daily allowance once it is used."""

import uuid
from datetime import date, datetime, timezone

import pytest

from app.core.config import settings
from app.models.llm_usage import LlmUsage
from app.models.segment import Segment
from app.models.user import User
from app.services import plans
from tests.conftest import TEST_USER_ID

TODAY = date(2026, 10, 24)


async def _speech(db, day: date, seconds: int, user_id=TEST_USER_ID, kind="stt"):
    db.add(LlmUsage(
        id=uuid.uuid4(), user_id=user_id, day=day, kind=kind, model=f"m-{uuid.uuid4().hex[:6]}",
        calls=1, input_units=seconds, output_units=0, cached_units=0,
    ))
    await db.commit()


async def _account(db, plan="free", user_id=TEST_USER_ID, email="erik@example.com"):
    db.add(User(id=user_id, email=email, password_hash="x", plan=plan))
    await db.commit()


async def _deferred(db, seconds: int, recorded_at: datetime):
    db.add(Segment(
        id=uuid.uuid4(), user_id=TEST_USER_ID, received_at=recorded_at, recorded_at=recorded_at,
        duration_ms=seconds * 1000, audio_path="/tmp/x.adpcm", transcription_status="deferred",
    ))
    await db.commit()


def test_the_default_plans():
    free, plus, unlimited = (plans.get_plan(n) for n in ("free", "plus", "unlimited"))

    assert (free.monthly_minutes, free.daily_minutes, free.web_searches_per_day, free.routines) == (
        300, 10, 5, 2
    )
    assert (plus.monthly_minutes, plus.web_searches_per_day, plus.routines) == (1500, 30, 10)
    assert (unlimited.monthly_minutes, unlimited.web_searches_per_day) == (9000, 60)
    assert plans.plan_names() == ["free", "plus", "unlimited"]


def test_an_unknown_plan_is_free():
    assert plans.get_plan("gold").name == "free"
    assert plans.get_plan(None).name == "free"


def test_settings_override_a_plan(monkeypatch):
    monkeypatch.setattr(settings, "plans", {"plus": {"monthly_minutes": 600}})

    plus = plans.get_plan("plus")

    assert plus.monthly_minutes == 600
    assert plus.web_searches_per_day == 30  # the rest stays as it was


def test_month_bounds():
    assert plans.month_start(TODAY) == date(2026, 10, 1)
    assert plans.next_month_start(TODAY) == date(2026, 11, 1)
    assert plans.next_month_start(date(2026, 12, 31)) == date(2027, 1, 1)


async def test_speech_counts_this_month_only(db_session):
    await _speech(db_session, date(2026, 9, 30), 500)
    await _speech(db_session, date(2026, 10, 2), 120)
    await _speech(db_session, date(2026, 10, 3), 60)
    await _speech(db_session, date(2026, 10, 3), 999, kind="llm")
    await _speech(db_session, date(2026, 10, 3), 777, user_id=uuid.uuid4())

    assert await plans.speech_seconds(db_session, TEST_USER_ID, date(2026, 10, 1)) == 180


async def test_may_transcribe_within_the_budget(db_session):
    await _speech(db_session, date(2026, 10, 2), 299 * 60)

    assert await plans.may_transcribe(db_session, TEST_USER_ID, late=False, today=TODAY)
    assert await plans.may_transcribe(db_session, TEST_USER_ID, late=True, today=TODAY)


async def test_past_the_budget_only_the_daily_allowance(db_session):
    await _speech(db_session, date(2026, 10, 2), 300 * 60)
    await _speech(db_session, TODAY, 9 * 60)

    # Today's first 10 minutes still go through; late speech waits for the budget
    assert await plans.may_transcribe(db_session, TEST_USER_ID, late=False, today=TODAY)
    assert not await plans.may_transcribe(db_session, TEST_USER_ID, late=True, today=TODAY)

    await _speech(db_session, TODAY, 60)
    assert not await plans.may_transcribe(db_session, TEST_USER_ID, late=False, today=TODAY)


async def test_a_raised_plan_has_room_again(db_session):
    await _account(db_session, plan="plus")
    await _speech(db_session, date(2026, 10, 2), 400 * 60)

    assert (await plans.user_plan(db_session, TEST_USER_ID)).name == "plus"
    assert await plans.may_transcribe(db_session, TEST_USER_ID, late=True, today=TODAY)


async def test_a_user_without_account_is_free(db_session):
    assert (await plans.user_plan(db_session, uuid.uuid4())).name == "free"


async def test_set_user_plan(db_session):
    await _account(db_session)

    user = await plans.set_user_plan(db_session, " Erik@Example.com ", "unlimited")

    assert user.plan == "unlimited"
    with pytest.raises(ValueError, match="unknown plan"):
        await plans.set_user_plan(db_session, "erik@example.com", "gold")
    with pytest.raises(ValueError, match="no such user"):
        await plans.set_user_plan(db_session, "ada@example.com", "plus")


async def test_plan_usage(db_session):
    await _speech(db_session, date(2026, 10, 2), 301 * 60)
    await _deferred(db_session, 40, datetime(2026, 10, 20, 9, tzinfo=timezone.utc))
    await _deferred(db_session, 20, datetime(2026, 10, 21, 9, tzinfo=timezone.utc))

    usage = await plans.plan_usage(db_session, TEST_USER_ID, today=TODAY)

    assert usage.plan.name == "free"
    assert usage.used_seconds == 301 * 60
    assert usage.budget_seconds == 300 * 60
    assert usage.over_budget is True
    assert usage.deferred_seconds == 60
    assert usage.resets_on == date(2026, 11, 1)
