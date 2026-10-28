"""A routine's runs: what it already reported, and the runs older than 90 days going away."""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.models.routine import Routine
from app.models.routine_run import RoutineRun
from app.services import routine_runs
from tests.conftest import TEST_USER_ID

NOW = datetime(2026, 10, 28, 6, 0, tzinfo=timezone.utc)


async def _routine(db) -> Routine:
    routine = Routine(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        instruction="nuove posizioni backend",
        schedule={"kind": "daily", "time": "07:00"},
        timezone="Europe/Rome",
        active=True,
        next_run_at=NOW,
        source="voice",
        mode="only_new",
    )
    db.add(routine)
    await db.flush()
    return routine


def _item(key: str) -> dict:
    return {"key": key, "title": key.upper(), "url": None}


async def test_seen_items_are_the_routines_own_newest_first_without_repeats(db_session):
    mine, other = await _routine(db_session), await _routine(db_session)
    for days, routine, keys in [
        (3, mine, ["a", "b"]),
        (1, mine, ["c", "a"]),
        (2, other, ["z"]),
    ]:
        db_session.add(
            RoutineRun(
                routine_id=routine.id,
                user_id=TEST_USER_ID,
                ran_at=NOW - timedelta(days=days),
                status="reported",
                items=[_item(k) for k in keys],
            )
        )
    await db_session.commit()

    seen = await routine_runs.seen_items(db_session, mine.id)

    assert [item["key"] for item in seen] == ["c", "a", "b"]


async def test_record_run_updates_the_routine(db_session):
    routine = await _routine(db_session)

    run = await routine_runs.record_run(
        db_session, routine, status="reported", ran_at=NOW, text="Sole", sources=[]
    )
    await db_session.commit()

    assert (run.status, run.text, run.items) == ("reported", "Sole", [])
    assert (routine.last_status, routine.last_answer, routine.last_run_at) == (
        "reported",
        "Sole",
        NOW,
    )


async def test_a_quiet_run_keeps_the_last_answer(db_session):
    routine = await _routine(db_session)
    routine.last_answer = "Ieri: 2 nuove"

    await routine_runs.record_run(db_session, routine, status="nothing", ran_at=NOW)

    assert (routine.last_status, routine.last_answer) == ("nothing", "Ieri: 2 nuove")


async def test_old_runs_are_deleted_after_90_days(db_session):
    routine = await _routine(db_session)
    for days in (91, 89):
        db_session.add(
            RoutineRun(
                routine_id=routine.id,
                user_id=TEST_USER_ID,
                ran_at=NOW - timedelta(days=days),
                status="nothing",
            )
        )
    await db_session.commit()

    assert await routine_runs.delete_old_runs(db_session, NOW) == 1

    left = (await db_session.scalars(select(RoutineRun))).all()
    assert [run.ran_at for run in left] == [NOW - timedelta(days=89)]
