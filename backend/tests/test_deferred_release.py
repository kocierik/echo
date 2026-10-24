"""Deferred speech goes back to transcription, oldest first, as far as the month's budget
allows: hourly, and at once when the operator raises a plan (make set-plan)."""

import argparse
import uuid
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select

from app.cli import users as users_cli
from app.models.llm_usage import LlmUsage
from app.models.segment import Segment
from app.models.user import User
from app.workers import deferred
from app.workers.stt import DEFERRED_STT_QUEUE
from tests.conftest import TEST_USER_ID, test_session
from tests.fakes.redis import InMemoryRedis

TODAY = date(2026, 11, 1)
START = datetime(2026, 10, 20, 9, tzinfo=timezone.utc)


class _Redis(InMemoryRedis):
    async def aclose(self):
        pass


async def _speech(db, day: date, seconds: int, user_id=TEST_USER_ID):
    db.add(LlmUsage(
        id=uuid.uuid4(), user_id=user_id, day=day, kind="stt",
        model=f"m-{uuid.uuid4().hex[:6]}", calls=1, input_units=seconds,
    ))
    await db.commit()


async def _deferred(db, minutes_after: int, seconds=40, user_id=TEST_USER_ID) -> uuid.UUID:
    at = START + timedelta(minutes=minutes_after)
    segment = Segment(
        id=uuid.uuid4(), user_id=user_id, received_at=at, recorded_at=at,
        duration_ms=seconds * 1000, audio_path="/data/audio/x.adpcm",
        transcription_status="deferred",
    )
    db.add(segment)
    await db.commit()
    return segment.id


def _pop_order(redis) -> list[str]:
    # lpush adds on the left and the worker pops from the right
    return list(reversed(redis.lists.get(DEFERRED_STT_QUEUE, [])))


async def test_release_queues_the_oldest_within_the_budget(db_session):
    await _speech(db_session, TODAY, 300 * 60 - 60)  # 60 s of the budget left
    newest = await _deferred(db_session, 30)
    oldest = await _deferred(db_session, 10)
    middle = await _deferred(db_session, 20)
    redis = _Redis()

    released = await deferred.release_deferred(redis, session_factory=test_session, today=TODAY)

    # 40 s fits, the second (80 s in all) is the one that crosses the budget: it goes too
    assert released == 2
    assert _pop_order(redis) == [str(oldest), str(middle)]
    assert str(newest) not in _pop_order(redis)


async def test_last_months_speech_does_not_count(db_session):
    await _speech(db_session, date(2026, 10, 31), 300 * 60)
    segment = await _deferred(db_session, 0)
    redis = _Redis()

    assert await deferred.release_deferred(redis, session_factory=test_session, today=TODAY) == 1
    assert _pop_order(redis) == [str(segment)]


async def test_no_release_past_the_budget(db_session):
    await _speech(db_session, TODAY, 300 * 60)
    await _deferred(db_session, 0)
    redis = _Redis()

    assert await deferred.release_deferred(redis, session_factory=test_session, today=TODAY) == 0
    assert _pop_order(redis) == []


async def test_no_release_while_the_queue_holds_some(db_session):
    await _deferred(db_session, 0)
    redis = _Redis()
    await redis.lpush(DEFERRED_STT_QUEUE, "already-queued")

    assert await deferred.release_deferred(redis, session_factory=test_session, today=TODAY) == 0
    assert _pop_order(redis) == ["already-queued"]


async def test_release_for_one_user(db_session):
    other = uuid.uuid4()
    mine = await _deferred(db_session, 0)
    await _deferred(db_session, 0, user_id=other)
    redis = _Redis()

    released = await deferred.release_deferred(
        redis, session_factory=test_session, user_id=TEST_USER_ID, today=TODAY
    )

    assert released == 1
    assert _pop_order(redis) == [str(mine)]


async def test_set_plan_cli_sets_and_releases(db_session, monkeypatch, capsys):
    db_session.add(User(id=TEST_USER_ID, email="erik@example.com", password_hash="x"))
    await db_session.commit()
    await _speech(db_session, datetime.now(timezone.utc).date(), 300 * 60)
    segment = await _deferred(db_session, 0)
    redis = _Redis()
    monkeypatch.setattr(users_cli, "_redis", lambda: redis)
    monkeypatch.setattr(users_cli, "async_session", test_session)

    await users_cli._main(argparse.Namespace(command="set-plan", email="erik@example.com",
                                             plan="plus"))

    plan = await db_session.scalar(select(User.plan).where(User.id == TEST_USER_ID))
    assert plan == "plus"
    assert _pop_order(redis) == [str(segment)]
    out = capsys.readouterr().out
    assert "erik@example.com is on plus" in out
    assert "1 deferred segment" in out


def test_worker_main_starts_the_deferred_loop():
    import inspect

    from app.workers import main as worker_main

    source = inspect.getsource(worker_main.main)
    assert "run_deferred_loop(redis_client, shutdown_event)" in source
    assert 'name="deferred_worker"' in source
