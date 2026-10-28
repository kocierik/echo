"""A routine's mode and its runs, as stored."""

import uuid
from datetime import datetime, timezone

from sqlalchemy import delete, select

from app.models.routine import Routine
from app.models.routine_run import RoutineRun
from tests.conftest import TEST_USER_ID

NOW = datetime(2026, 10, 28, 6, 0, tzinfo=timezone.utc)


def _routine() -> Routine:
    return Routine(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        instruction="dimmi che tempo fa a Milano",
        schedule={"kind": "daily", "time": "07:00"},
        timezone="Europe/Rome",
        active=True,
        next_run_at=NOW,
        source="voice",
    )


async def test_a_routine_is_always_by_default(db_session):
    routine = _routine()
    routine_id = routine.id
    db_session.add(routine)
    await db_session.commit()
    db_session.expire_all()

    stored = await db_session.get(Routine, routine_id)
    assert stored.mode == "always"


async def test_runs_go_with_their_routine(db_session):
    routine = _routine()
    db_session.add(routine)
    await db_session.flush()
    routine_id = routine.id
    db_session.add(
        RoutineRun(
            routine_id=routine_id,
            user_id=TEST_USER_ID,
            ran_at=NOW,
            status="reported",
            text="Sole",
            items=[{"key": "k", "title": "t", "url": None}],
        )
    )
    await db_session.commit()
    runs = (await db_session.scalars(select(RoutineRun))).all()
    assert [(r.status, r.text, r.sources, r.items[0]["key"]) for r in runs] == [
        ("reported", "Sole", [], "k")
    ]

    await db_session.execute(delete(Routine).where(Routine.id == routine_id))
    await db_session.commit()
    left = (
        await db_session.scalars(select(RoutineRun).where(RoutineRun.routine_id == routine_id))
    ).all()
    assert left == []
