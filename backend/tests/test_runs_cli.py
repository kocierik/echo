"""`make runs` (app/cli/runs.py): one run by correlation ID, or one user's last runs."""

import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

from app.cli import runs as runs_cli
from app.models import AgentRun, AgentStep, User
from tests.conftest import TEST_USER_ID, test_session

OTHER_USER_ID = uuid.UUID("b0000000-0000-0000-0000-000000000002")
START = datetime(2026, 10, 30, 9, 0, tzinfo=timezone.utc)


async def _users():
    async with test_session() as db:
        db.add_all([
            User(id=TEST_USER_ID, email="erik@example.com", password_hash="x"),
            User(id=OTHER_USER_ID, email="ada@example.com", password_hash="x"),
        ])
        await db.commit()


async def _run(cid, user_id=TEST_USER_ID, *, minutes=0, unknown=False, steps=()):
    started = START + timedelta(minutes=minutes)
    run = AgentRun(
        correlation_id=cid, user_id=user_id, source="chat", status="completed",
        started_at=started, ended_at=started + timedelta(seconds=4),
        tokens_in=1200, tokens_out=80, cost_usd=Decimal("0.000160"), cost_unknown=unknown,
    )
    async with test_session() as db:
        db.add(run)
        await db.flush()
        for seq, (kind, agent, cost, step_unknown) in enumerate(steps, start=1):
            db.add(AgentStep(
                run_id=run.id, seq=seq, kind=kind, agent_id=agent, status="ok",
                started_at=started, duration_ms=100 * seq, cost_usd=cost,
                cost_unknown=step_unknown, model="gpt-6-luna" if kind == "llm_call" else None,
                tool_name="GMAIL_FETCH_EMAILS" if kind == "tool_call" else None,
                tier="READ" if kind == "tool_call" else None,
            ))
        await db.commit()
    return run


async def _report(*argv) -> str:
    return await runs_cli.report(runs_cli.parse_args(argv), session_factory=test_session)


async def test_by_correlation_id_the_run_and_its_steps_in_order():
    await _run("cid-show", steps=[
        ("plan", "coordinator", Decimal("0.000050"), False),
        ("tool_call", "actions", Decimal(0), False),
        ("llm_call", "actions", Decimal("0.000110"), False),
    ])
    await _run("cid-other")

    text = await _report("--cid", "cid-show")

    assert "estimates" in text and "cid-other" not in text
    lines = [line for line in text.splitlines() if line.startswith("    ")]
    assert [line.split()[1] for line in lines] == ["plan", "tool_call", "llm_call"]
    assert "GMAIL_FETCH_EMAILS [READ]" in text and "~$0.000160" in text
    assert "4.0 s" in text and "partial" not in text


async def test_by_user_only_that_users_runs_newest_first_with_cost_per_agent():
    await _users()
    await _run("cid-erik-1", minutes=1, steps=[("llm_call", "memory", Decimal("0.0001"), False)])
    await _run("cid-erik-2", minutes=2, steps=[("llm_call", "actions", Decimal("0.0002"), False)])
    await _run("cid-ada", OTHER_USER_ID, minutes=3)

    text = await _report("--user", " ERIK@example.com ")

    assert "cid-ada" not in text
    assert text.index("cid-erik-2") < text.index("cid-erik-1")
    assert "memory" in text and "actions" in text and "~$0.000200" in text

    by_id = await _report("--user", str(OTHER_USER_ID), "--last", "1")
    assert "cid-ada" in by_id and "cid-erik" not in by_id


async def test_last_limits_how_many_runs_are_shown():
    await _users()
    for minute in range(3):
        await _run(f"cid-{minute}", minutes=minute)

    text = await _report("--user", "erik@example.com", "--last", "2")

    assert "Last 2 run(s)" in text and "cid-0" not in text


async def test_a_run_with_an_unpriced_model_shows_a_partial_cost():
    await _run("cid-unknown", unknown=True, steps=[("llm_call", "memory", Decimal(0), True)])

    text = await _report("--cid", "cid-unknown")

    assert text.count("partial cost") == 2  # the run and its step


@pytest.mark.parametrize(
    "argv, message",
    [
        (("--cid", "nope"), "No tracked run with correlation ID nope."),
        (("--user", "nobody@example.com"), "No user with e-mail nobody@example.com."),
        (("--user", str(uuid.uuid4())), "No user with id"),
        (("--cid", "  "), "Give a correlation ID"),
        (("--user", "erik@example.com", "--last", "0"), "LAST must be 1 or more."),
    ],
)
async def test_unknown_values_are_refused_with_a_message(argv, message):
    await _users()
    with pytest.raises(runs_cli.RunsError, match=message):
        await _report(*argv)


async def test_a_known_user_without_runs_is_not_an_error():
    await _users()

    assert await _report("--user", "ada@example.com") == "No tracked runs for ada@example.com."


@pytest.mark.parametrize("argv", [(), ("--cid", "a", "--user", "b"), ("--last", "3")])
def test_missing_or_conflicting_arguments_exit_with_an_error(argv, capsys):
    with pytest.raises(SystemExit) as exit_info:
        runs_cli.parse_args(argv)

    assert exit_info.value.code != 0
    assert "--cid" in capsys.readouterr().err


def test_main_exits_non_zero_with_the_message(monkeypatch):
    async def refuse(args):
        raise runs_cli.RunsError("No tracked run with correlation ID x.")

    def run_inline(coroutine):
        # Not asyncio.run: it would leave this thread without the tests' event loop
        coroutine.send(None)

    monkeypatch.setattr(runs_cli, "report", refuse)
    monkeypatch.setattr(runs_cli.asyncio, "run", run_inline)

    with pytest.raises(SystemExit) as exit_info:
        runs_cli.main(["--cid", "x"])

    assert exit_info.value.code == "No tracked run with correlation ID x."
