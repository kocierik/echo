"""Run tracking (core/runs.py): runs and their steps on the echo_test database.

Tracking is switched on per test (`tracking`); with it off nothing may be written. Old
runs are made by writing `started_at` in the past, never by waiting.
"""

import asyncio
import json
import logging
import os
import statistics
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import func, select, update

from app import usage_prices
from app.core import database, runs
from app.core.config import settings
from app.core.logging import JSONFormatter
from app.models import AgentRun, AgentStep
from tests.conftest import TEST_USER_ID, test_session

OTHER_USER_ID = uuid.UUID("b0000000-0000-0000-0000-000000000002")


@pytest.fixture
def tracking(monkeypatch):
    monkeypatch.setattr(settings, "run_tracking_enabled", True)


async def _runs() -> list[AgentRun]:
    async with test_session() as db:
        return (await db.scalars(select(AgentRun).order_by(AgentRun.started_at))).all()


async def _steps(run_id) -> list[AgentStep]:
    async with test_session() as db:
        query = select(AgentStep).where(AgentStep.run_id == run_id).order_by(AgentStep.seq)
        return (await db.scalars(query)).all()


async def _count(model) -> int:
    async with test_session() as db:
        return await db.scalar(select(func.count()).select_from(model))


class _FailingSession:
    """A session factory and session whose every write fails, with values in the message."""

    def __call__(self):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    def add(self, obj):
        pass

    async def execute(self, *args, **kwargs):
        raise ConnectionRefusedError("password=hunter2 for ada@example.com")

    async def commit(self):
        raise ConnectionRefusedError("password=hunter2 for ada@example.com")


# --- Opening and closing ----------------------------------------------------------------


async def test_a_run_is_opened_and_closed_with_its_totals(tracking):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-0001")
    assert runs.current_run() is run and run.run_id is not None

    [stored] = await _runs()
    assert (stored.status, stored.ended_at, stored.correlation_id) == (
        "running", None, "cid-0001"
    )

    await runs.record_step("llm_call", model="gpt-6-luna", tokens_in=1000, tokens_out=200)
    await runs.close_run(run, "completed", plan_summary="memory,actions")

    [stored] = await _runs()
    assert stored.status == "completed" and stored.ended_at >= stored.started_at
    assert (stored.tokens_in, stored.tokens_out) == (1000, 200)
    # 1000 x 0.10 + 200 x 0.50 per million tokens
    assert stored.cost_usd == Decimal("0.000200") and stored.cost_unknown is False
    assert (stored.user_id, stored.source, stored.plan_summary) == (
        TEST_USER_ID, "chat", "memory,actions"
    )


async def test_the_request_correlation_id_is_used_when_none_is_given(tracking):
    from app.core.logging import correlation_id

    correlation_id.set("req-42")
    run = await runs.open_run(TEST_USER_ID, "voice")

    assert run.correlation_id == "req-42"
    assert (await _runs())[0].correlation_id == "req-42"


async def test_a_run_ends_once(tracking, caplog):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-once")
    await runs.close_run(run, "timeout")

    with caplog.at_level(logging.WARNING, logger="app.core.runs"):
        await runs.close_run(run, "completed")

    [stored] = await _runs()
    assert stored.status == "timeout"
    assert any("already closed" in r.getMessage() for r in caplog.records)


async def test_a_run_closed_as_interrupted_keeps_that_status(tracking, caplog):
    run = await runs.open_run(TEST_USER_ID, "routine", "cid-late")
    async with test_session() as db:
        await db.execute(
            update(AgentRun)
            .where(AgentRun.id == run.run_id)
            .values(status="interrupted", ended_at=datetime.now(timezone.utc))
        )
        await db.commit()

    with caplog.at_level(logging.WARNING, logger="app.core.runs"):
        await runs.close_run(run, "completed")

    assert (await _runs())[0].status == "interrupted"
    assert any("no longer running" in r.getMessage() for r in caplog.records)


async def test_a_running_status_or_unknown_source_is_a_programming_error(tracking):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-bad")
    with pytest.raises(ValueError):
        await runs.close_run(run, "running")
    with pytest.raises(ValueError):
        await runs.open_run(TEST_USER_ID, "email", "cid-bad")


async def test_the_plan_summary_keeps_only_agent_ids(tracking):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-plan")
    instructions = "Search the mail of Ada about the Atlas budget, then write to Bob"

    await runs.close_run(run, "completed", plan_summary=["memory", instructions, "actions"])

    assert (await _runs())[0].plan_summary == "memory,actions"


# --- Steps ------------------------------------------------------------------------------


async def test_steps_are_numbered_in_order_and_concurrent_ones_never_share_a_number(tracking):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-seq")
    await runs.record_step("plan", agent_id="coordinator")
    await asyncio.gather(*(runs.record_step("tool_call", tool_name=f"T{i}") for i in range(5)))
    await runs.record_step("synthesis")

    steps = await _steps(run.run_id)
    assert [s.seq for s in steps] == list(range(1, 8))
    assert steps[0].kind == "plan" and steps[-1].kind == "synthesis"


async def test_tool_arguments_are_stored_reduced_to_their_shape(tracking):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-args")
    log_id = uuid.uuid4()

    await runs.record_step(
        "tool_call", agent_id="actions", tool_name="GMAIL_SEND_EMAIL", tier="CONFIRM",
        status="refused", args={"to": "ada@example.com", "body": "Ciao", "thread_id": "t1"},
        action_log_id=log_id, duration_ms=40,
    )

    [step] = await _steps(run.run_id)
    assert step.args_redacted == {"to": "str(15)", "body": "str(4)", "thread_id": "t1"}
    assert (step.status, step.tier, step.action_log_id, step.duration_ms) == (
        "refused", "CONFIRM", log_id, 40
    )
    assert step.started_at <= datetime.now(timezone.utc) - timedelta(milliseconds=40)


async def test_no_step_is_written_outside_a_run(tracking):
    await runs.record_step("llm_call", model="gpt-6-luna", tokens_in=10)

    assert await _count(AgentStep) == 0


async def test_an_invalid_step_is_logged_never_raised(tracking, caplog):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-kind")

    with caplog.at_level(logging.WARNING, logger="app.core.runs"):
        await runs.record_step("thinking")

    assert await _steps(run.run_id) == []
    assert caplog.records[-1].error_class == "ValueError"


async def test_with_tracking_off_nothing_is_written():
    assert settings.run_tracking_enabled is False  # the default

    async with runs.run_scope(TEST_USER_ID, "chat", "cid-off") as run:
        await runs.record_step("llm_call", model="gpt-6-luna", tokens_in=10)
        await runs.record_step("tool_call", tool_name="T")
    assert run.run_id is None and run.closed

    assert await _count(AgentRun) == 0 and await _count(AgentStep) == 0


# --- Cost -------------------------------------------------------------------------------


async def test_a_model_without_a_price_costs_nothing_and_is_marked(tracking, monkeypatch):
    monkeypatch.delitem(usage_prices.PRICES, "gpt-6-luna")
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-cost")

    await runs.record_step("llm_call", model="gpt-6-luna", tokens_in=500, tokens_out=50)
    await runs.record_step("tool_call", tool_name="T")  # no tokens: known, free
    await runs.close_run(run, "completed")

    llm, tool = await _steps(run.run_id)
    assert (llm.cost_usd, llm.cost_unknown) == (0, True)
    assert (tool.cost_usd, tool.cost_unknown) == (0, False)
    [stored] = await _runs()
    assert (stored.cost_usd, stored.cost_unknown, stored.tokens_in) == (0, True, 500)


def test_cached_tokens_use_the_cached_price_or_else_the_input_price(monkeypatch):
    # gpt-6-luna: 0.10 input, 0.01 cached, 0.50 output per 1M
    assert runs.step_cost("gpt-6-luna", 1000, 0, 400) == (Decimal("0.000064"), False)
    monkeypatch.setitem(
        usage_prices.PRICES, "no-cache-model", {"unit": "token", "input": 1.0, "output": 2.0}
    )
    assert runs.step_cost("no-cache-model", 1000, 500, 400) == (Decimal("0.002000"), False)
    # Priced per second of audio, not per token: unknown as a model call
    assert runs.step_cost("nova-3", 10, 0) == (Decimal(0), True)
    assert runs.step_cost(None, 0, 0) == (Decimal(0), False)


# --- Failures never reach the request ---------------------------------------------------


async def test_a_database_failure_never_fails_the_request(tracking, monkeypatch, caplog):
    monkeypatch.setattr(runs, "get_session_factory", lambda: _FailingSession())

    with caplog.at_level(logging.WARNING, logger="app.core.runs"):
        async with runs.run_scope(TEST_USER_ID, "chat", "cid-down") as run:
            await runs.record_step("plan")
        closed = await runs.close_interrupted(180)

    assert run.run_id is None and closed == 0
    failures = [r for r in caplog.records if "write failed" in r.getMessage()]
    assert [r.error_class for r in failures] == ["ConnectionRefusedError"] * 2
    assert all("hunter2" not in r.getMessage() and not r.exc_info for r in failures)


async def test_a_failed_step_write_is_logged_with_the_run_id(tracking, monkeypatch, caplog):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-step-down")
    monkeypatch.setattr(runs, "get_session_factory", lambda: _FailingSession())

    with caplog.at_level(logging.WARNING, logger="app.core.runs"):
        await runs.record_step("tool_call", args={"body": "hunter2"})
        await runs.close_run(run, "completed")

    failures = [r for r in caplog.records if "write failed" in r.getMessage()]
    assert [r.run_id for r in failures] == [run.run_id, run.run_id]
    line = json.loads(JSONFormatter().format(failures[0]))
    assert line["run_id"] == str(run.run_id) and line["error_class"] == "ConnectionRefusedError"
    assert "hunter2" not in json.dumps(line)


# --- run_scope and agent_scope ----------------------------------------------------------


async def test_run_scope_completes_or_fails_with_the_exception_class(tracking):
    async with runs.run_scope(TEST_USER_ID, "chat", "cid-ok"):
        pass
    with pytest.raises(KeyError):
        async with runs.run_scope(TEST_USER_ID, "chat", "cid-fail"):
            raise KeyError("ada@example.com")
    async with runs.run_scope(TEST_USER_ID, "chat", "cid-timeout") as run:
        await runs.close_run(run, "timeout")

    by_cid = {r.correlation_id: r for r in await _runs()}
    assert by_cid["cid-ok"].status == "completed"
    assert (by_cid["cid-fail"].status, by_cid["cid-fail"].error_class) == ("failed", "KeyError")
    assert by_cid["cid-timeout"].status == "timeout"
    assert runs.current_run() is None  # the previous run (none) is back


async def test_run_scope_closes_a_cancelled_run_as_failed_and_cancels(tracking):
    started = asyncio.Event()

    async def request():
        async with runs.run_scope(TEST_USER_ID, "voice", "cid-cancel"):
            started.set()
            await asyncio.sleep(30)

    task = asyncio.create_task(request())
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    [stored] = await _runs()
    assert (stored.status, stored.error_class) == ("failed", "cancelled")


async def test_two_users_at_once_each_get_only_their_own_run_and_steps(tracking):
    async def request(user_id, cid):
        async with runs.run_scope(user_id, "chat", cid) as run:
            for i in range(3):
                await runs.record_step("tool_call", tool_name=f"{cid}-{i}")
                await asyncio.sleep(0)
        return run

    first, second = await asyncio.gather(
        request(TEST_USER_ID, "cid-a"), request(OTHER_USER_ID, "cid-b")
    )

    by_cid = {r.correlation_id: r for r in await _runs()}
    assert by_cid["cid-a"].user_id == TEST_USER_ID
    assert by_cid["cid-b"].user_id == OTHER_USER_ID
    assert [s.tool_name for s in await _steps(first.run_id)] == ["cid-a-0", "cid-a-1", "cid-a-2"]
    assert [s.tool_name for s in await _steps(second.run_id)] == [
        "cid-b-0", "cid-b-1", "cid-b-2"
    ]


async def test_agents_side_by_side_each_name_their_own_steps(tracking):
    run = await runs.open_run(TEST_USER_ID, "chat", "cid-agents")

    async def agent(name):
        with runs.agent_scope(name):
            assert runs.current_run().current_agent == name
            await asyncio.sleep(0)
            await runs.record_step("llm_call", agent_id=runs.current_run().current_agent)

    await asyncio.gather(agent("memory"), agent("actions"))

    assert sorted(s.agent_id for s in await _steps(run.run_id)) == ["actions", "memory"]
    assert run.current_agent is None


# --- Interrupted runs and retention -----------------------------------------------------


async def _old_run(cid: str, age: timedelta, status: str = "running") -> uuid.UUID:
    started = datetime.now(timezone.utc) - age
    run = AgentRun(
        correlation_id=cid, user_id=TEST_USER_ID, source="chat", status=status,
        started_at=started, ended_at=None if status == "running" else started,
    )
    async with test_session() as db:
        db.add(run)
        await db.flush()
        db.add(AgentStep(run_id=run.id, seq=1, kind="plan", status="ok", started_at=started))
        await db.commit()
    return run.id


async def test_runs_past_the_threshold_are_closed_as_interrupted_once():
    await _old_run("cid-100s", timedelta(seconds=100))
    await _old_run("cid-200s", timedelta(seconds=200))
    await _old_run("cid-done", timedelta(seconds=300), status="completed")

    assert await runs.close_interrupted(180) == 1
    assert await runs.close_interrupted(180) == 0  # idempotent

    by_cid = {r.correlation_id: r for r in await _runs()}
    assert by_cid["cid-100s"].status == "running"
    old = by_cid["cid-200s"]
    assert (old.status, old.error_class) == ("interrupted", "interrupted")
    assert old.ended_at is not None
    assert by_cid["cid-done"].status == "completed"


async def test_purge_deletes_runs_older_than_the_days_with_their_steps():
    kept = await _old_run("cid-29d", timedelta(days=29))
    await _old_run("cid-31d", timedelta(days=31), status="completed")

    assert await runs.purge_older_than(30) == 1

    assert [r.id for r in await _runs()] == [kept]
    assert await _count(AgentStep) == 1


def test_the_threshold_warning_names_a_value_below_timeout_plus_85(monkeypatch):
    assert runs.interrupted_threshold_warning(45) is None  # 180 >= 130
    monkeypatch.setattr(settings, "run_interrupted_after_seconds", 120)
    assert "below 130 s" in runs.interrupted_threshold_warning(45)


async def test_at_startup_a_low_threshold_is_logged_and_old_runs_are_closed(
    monkeypatch, caplog
):
    await _old_run("cid-left", timedelta(seconds=150))
    monkeypatch.setattr(settings, "run_interrupted_after_seconds", 120)

    with caplog.at_level(logging.WARNING, logger="app.core.runs"):
        assert await runs.startup_close_interrupted() == 1

    assert any("below 130 s" in r.getMessage() for r in caplog.records)


async def test_the_api_startup_sweep_leaves_the_shared_pool_usable():
    # TestClient runs the lifespan on its own event loop, as a second loop would: the
    # startup sweep must not leave a connection bound to that loop in the shared pool
    from fastapi.testclient import TestClient

    from app.main import app

    await _old_run("cid-before-start", timedelta(seconds=500))
    for _ in range(3):
        with TestClient(app):
            pass
        async with database.async_session() as db:
            assert await db.scalar(select(func.count()).select_from(AgentRun)) == 1

    assert (await _runs())[0].status == "interrupted"


async def test_the_worker_sweeps_at_start_and_stops_on_shutdown(monkeypatch):
    from app.workers import main as worker_main

    swept = []

    async def close(older_than_seconds, session_factory=None):
        swept.append(older_than_seconds)
        return 0

    monkeypatch.setattr(runs, "close_interrupted", close)
    monkeypatch.setattr(worker_main, "close_interrupted", close)
    monkeypatch.setattr(worker_main, "INTERRUPTED_SWEEP_INTERVAL_S", 0.01)
    shutdown = asyncio.Event()

    loop = asyncio.create_task(worker_main.run_interrupted_sweep_loop(shutdown))
    await asyncio.sleep(0.05)
    shutdown.set()
    await asyncio.wait_for(loop, timeout=1)

    assert len(swept) >= 2 and set(swept) == {180}


async def test_retention_deletes_old_runs_even_when_the_audio_cleanup_fails(monkeypatch):
    from app.workers import retention

    async def broken_cleanup():
        raise RuntimeError("disk")

    monkeypatch.setattr(retention, "cleanup_old_audio", broken_cleanup)
    await _old_run("cid-40d", timedelta(days=40), status="completed")
    shutdown = asyncio.Event()

    loop = asyncio.create_task(retention.run_retention_loop(shutdown))
    for _ in range(100):
        if not await _runs():
            break
        await asyncio.sleep(0.02)
    shutdown.set()
    await asyncio.wait_for(loop, timeout=2)

    assert await _runs() == []


async def test_a_failing_purge_never_stops_the_audio_cleanup(monkeypatch):
    from app.workers import retention

    cleaned = []

    async def cleanup():
        cleaned.append(1)
        return 0

    async def broken_purge(days):
        raise RuntimeError("database down")

    monkeypatch.setattr(retention, "cleanup_old_audio", cleanup)
    monkeypatch.setattr(retention, "purge_older_than", broken_purge)
    monkeypatch.setattr(retention, "RETENTION_CHECK_INTERVAL_S", 0.01)
    shutdown = asyncio.Event()

    loop = asyncio.create_task(retention.run_retention_loop(shutdown))
    await asyncio.sleep(0.05)
    shutdown.set()
    await asyncio.wait_for(loop, timeout=1)

    assert len(cleaned) >= 2


# --- Speed ------------------------------------------------------------------------------


async def _warm_pool(connections: int) -> None:
    """Open the tracking engine's pooled connections once, as a running api has them.

    A new PostgreSQL connection costs ~0.1 s here (password hashing), ~1 s when ten open
    at once: paid once per process, not per step, so it is not what the target measures.
    """
    held = []
    try:
        for _ in range(connections):
            connection = database.engine.connect()
            held.append(connection)
        await asyncio.gather(*(c.start() for c in held))
    finally:
        await asyncio.gather(*(c.close() for c in held))


# A measure of speed, not of correctness: on a shared CI runner (CI is set) or with coverage
# tracing every line (make coverage-new) it measures the machine; make test-all runs it
_SPEED_UNRELIABLE = bool(os.environ.get("CI")) or sys.gettrace() is not None


@pytest.mark.skipif(_SPEED_UNRELIABLE, reason="timing is unreliable on CI or under coverage")
@pytest.mark.timeout(30)
async def test_record_step_p95_stays_under_50_ms(tracking):
    await _warm_pool(10)
    await runs.open_run(TEST_USER_ID, "chat", "cid-speed")
    durations: list[float] = []

    async def writer(n):
        for i in range(20):
            started = time.perf_counter()
            await runs.record_step("tool_call", tool_name=f"T{n}-{i}", args={"limit": i})
            durations.append((time.perf_counter() - started) * 1000)

    await asyncio.gather(*(writer(n) for n in range(10)))

    assert len(durations) == 200
    p95 = statistics.quantiles(durations, n=100)[94]
    assert p95 < 50, f"p95 of record_step is {p95:.1f} ms"
    assert await _count(AgentStep) == 200
