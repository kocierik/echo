"""The run tracking tables: a run and its numbered steps, deleted together.

On the echo_test database (the constraints are PostgreSQL's), plus the 031 migration on
the fake `op` of test_migrations.py.
"""

import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError

from app.models import AgentRun, AgentStep
from tests.conftest import TEST_USER_ID, test_session
from tests.test_migrations import VERSIONS, _load, _migrations, _run, _State

NOW = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)


def _run_row(**values) -> AgentRun:
    defaults = dict(
        correlation_id="c0ffee01", user_id=TEST_USER_ID, source="chat", started_at=NOW
    )
    return AgentRun(**{**defaults, **values})


def _step(run: AgentRun, seq: int, **values) -> AgentStep:
    defaults = dict(
        run_id=run.id, seq=seq, kind="llm_call", status="ok", started_at=NOW, duration_ms=12
    )
    return AgentStep(**{**defaults, **values})


async def test_a_run_and_its_steps_are_stored_with_their_defaults():
    async with test_session() as db:
        run = _run_row()
        db.add(run)
        await db.flush()
        db.add_all([
            _step(run, 1, agent_id="actions", model="gpt-6-luna", tokens_in=100, tokens_out=20,
                  cost_usd=Decimal("0.00002")),
            _step(run, 2, kind="tool_call", tool_name="GMAIL_SEND_EMAIL", tier="CONFIRM",
                  args_redacted={"subject": "str(12)"}),
        ])
        await db.commit()

    async with test_session() as db:
        stored = await db.get(AgentRun, run.id)
        steps = (await db.scalars(
            select(AgentStep).where(AgentStep.run_id == run.id).order_by(AgentStep.seq)
        )).all()

    assert stored.status == "running" and stored.ended_at is None
    assert (stored.tokens_in, stored.cost_usd, stored.cost_unknown) == (0, 0, False)
    assert [s.seq for s in steps] == [1, 2]
    assert steps[0].cost_usd == Decimal("0.000020") and steps[0].attempt == 1
    assert steps[1].args_redacted == {"subject": "str(12)"} and steps[1].tier == "CONFIRM"


async def test_two_steps_with_the_same_seq_are_refused():
    async with test_session() as db:
        run = _run_row()
        db.add(run)
        await db.flush()
        db.add_all([_step(run, 1), _step(run, 1)])
        with pytest.raises(IntegrityError):
            await db.commit()


async def test_deleting_a_run_deletes_its_steps():
    async with test_session() as db:
        run = _run_row()
        db.add(run)
        await db.flush()
        db.add_all([_step(run, 1), _step(run, 2)])
        await db.commit()

        await db.execute(delete(AgentRun).where(AgentRun.id == run.id))
        await db.commit()

        assert await db.scalar(select(func.count()).select_from(AgentStep)) == 0


@pytest.mark.parametrize(
    "status, ended_at",
    [
        ("completed", None),  # a final status needs its end
        ("running", NOW + timedelta(seconds=5)),  # a running run has none
        ("failed", NOW - timedelta(seconds=5)),  # never before it started
    ],
)
async def test_the_end_matches_the_status(status, ended_at):
    async with test_session() as db:
        db.add(_run_row(status=status, ended_at=ended_at))
        with pytest.raises(IntegrityError):
            await db.commit()


async def test_a_step_needs_an_existing_run():
    async with test_session() as db:
        db.add(AgentStep(run_id=uuid.uuid4(), seq=1, kind="plan", status="ok", started_at=NOW))
        with pytest.raises(IntegrityError):
            await db.commit()


def test_migration_031_adds_the_two_tables_and_drops_them_on_downgrade(monkeypatch):
    state = _State()
    for module in _migrations():
        _run(module, state, monkeypatch)

    steps = state.tables["agent_steps"]
    [fk] = steps["fks"]
    assert (fk["referred_table"], fk["options"]) == ("agent_runs", {"ondelete": "CASCADE"})
    assert steps["columns"]["run_id"] is False and steps["columns"]["args_redacted"] is True
    indexes = {i["name"]: i["column_names"] for i in state.tables["agent_runs"]["indexes"]}
    assert indexes == {
        "ix_agent_runs_user_started": ["user_id", "started_at"],
        "ix_agent_runs_correlation_id": ["correlation_id"],
        "ix_agent_runs_started_at": ["started_at"],
    }

    migration_031 = _load(VERSIONS / "031_agent_runs.py")
    monkeypatch.setattr(migration_031, "op", op := _FakeDrop(state))
    migration_031.downgrade()
    assert op.dropped == ["agent_steps", "agent_runs"]
    assert {"agent_runs", "agent_steps"}.isdisjoint(state.tables)


class _FakeDrop:
    def __init__(self, state: _State):
        self.state = state
        self.dropped: list[str] = []

    def drop_table(self, name):
        self.dropped.append(name)
        del self.state.tables[name]
