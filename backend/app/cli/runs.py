"""What a request or a routine run did, step by step (run tracking, core/runs.py).

    python -m app.cli.runs --cid <correlation id>
    python -m app.cli.runs --user <email or user id> [--last 10]

By correlation ID (the X-Correlation-ID of a response, or the `correlation_id` of a log
line): the run and every step in order. By user: that user's last runs, newest first,
each with its cost per agent; never another user's. Costs are estimates from
app/usage_prices.py, marked partial when a model has no price. Nothing here is exposed
over HTTP: the operator runs it in the api container (`make runs`).
"""

import argparse
import asyncio
import sys
import uuid
from collections import defaultdict
from collections.abc import Sequence
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import async_session
from app.models.agent_run import AgentRun, AgentStep
from app.models.user import User


class RunsError(Exception):
    """Wrong or unknown arguments: the message is printed and the exit code is 1."""


def _cost(usd: Decimal, unknown: bool) -> str:
    text = f"~${usd:.6f}"
    return f"{text} (partial cost: a model has no price)" if unknown else text


def _duration(run: AgentRun) -> str:
    if run.ended_at is None:
        return "still running"
    return f"{(run.ended_at - run.started_at).total_seconds():.1f} s"


def _run_line(run: AgentRun) -> str:
    error = f" ({run.error_class})" if run.error_class else ""
    return (
        f"{run.started_at:%Y-%m-%d %H:%M:%S} UTC  {run.source}  {run.status}{error}  "
        f"{_duration(run)}  tokens {run.tokens_in} in / {run.tokens_out} out  "
        f"cost {_cost(run.cost_usd, run.cost_unknown)}  cid {run.correlation_id}"
    )


def _step_line(step: AgentStep) -> str:
    who = step.agent_id or "-"
    what = step.tool_name or step.model or "-"
    tier = f" [{step.tier}]" if step.tier else ""
    error = f" ({step.error_class})" if step.error_class else ""
    return (
        f"  {step.seq:>3}. {step.kind:<10} {who:<12} {what}{tier}  {step.status}{error}  "
        f"{step.duration_ms} ms  tokens {step.tokens_in}/{step.tokens_out}  "
        f"{_cost(step.cost_usd, step.cost_unknown)}  attempt {step.attempt}"
    )


def _agent_costs(steps: Sequence[AgentStep]) -> list[str]:
    costs: dict[str, Decimal] = defaultdict(Decimal)
    unknown: dict[str, bool] = defaultdict(bool)
    for step in steps:
        agent = step.agent_id or "(no agent)"
        costs[agent] += step.cost_usd
        unknown[agent] = unknown[agent] or step.cost_unknown
    return [f"  {agent:<12} {_cost(costs[agent], unknown[agent])}" for agent in sorted(costs)]


async def _steps_of(db: AsyncSession, run_ids: list[uuid.UUID]) -> dict:
    steps = (
        await db.scalars(
            select(AgentStep)
            .where(AgentStep.run_id.in_(run_ids))
            .order_by(AgentStep.run_id, AgentStep.seq)
        )
    ).all()
    by_run: dict = defaultdict(list)
    for step in steps:
        by_run[step.run_id].append(step)
    return by_run


async def runs_by_correlation(db: AsyncSession, cid: str) -> str:
    """The runs with this correlation ID (usually one) and all their steps."""
    cid = cid.strip()
    if not cid:
        raise RunsError("Give a correlation ID: make runs CID=<id>")
    runs = (
        await db.scalars(
            select(AgentRun).where(AgentRun.correlation_id == cid).order_by(AgentRun.started_at)
        )
    ).all()
    if not runs:
        raise RunsError(f"No tracked run with correlation ID {cid}.")
    steps = await _steps_of(db, [run.id for run in runs])
    lines = ["Costs are estimates (app/usage_prices.py)."]
    for run in runs:
        lines += ["", f"user {run.user_id or '-'}", _run_line(run)]
        lines += [_step_line(step) for step in steps[run.id]] or ["  (no steps)"]
    return "\n".join(lines)


async def _find_user(db: AsyncSession, who: str) -> tuple[uuid.UUID, str]:
    """The user's id and how to name them, by e-mail or id."""
    who = who.strip()
    if not who:
        raise RunsError("Give a user: make runs USER=<email or id>")
    try:
        user_id = uuid.UUID(who)
    except ValueError:
        user = await db.scalar(select(User).where(User.email == who.lower()))
        if user is None:
            raise RunsError(f"No user with e-mail {who.lower()}.") from None
        return user.id, user.email
    user = await db.get(User, user_id)
    if user is not None:
        return user.id, user.email
    has_runs = await db.scalar(select(AgentRun.id).where(AgentRun.user_id == user_id).limit(1))
    if has_runs is None:
        raise RunsError(f"No user with id {user_id}.")
    return user_id, str(user_id)


async def runs_of_user(db: AsyncSession, who: str, last: int = 10) -> str:
    """The user's last `last` runs, newest first, each with its cost per agent."""
    if last < 1:
        raise RunsError("LAST must be 1 or more.")
    user_id, name = await _find_user(db, who)
    runs = (
        await db.scalars(
            select(AgentRun)
            .where(AgentRun.user_id == user_id)
            .order_by(AgentRun.started_at.desc())
            .limit(last)
        )
    ).all()
    if not runs:
        return f"No tracked runs for {name}."
    steps = await _steps_of(db, [run.id for run in runs])
    lines = [f"Last {len(runs)} run(s) of {name}; costs are estimates (app/usage_prices.py)."]
    for run in runs:
        lines += ["", _run_line(run), f"  {len(steps[run.id])} step(s); cost per agent:"]
        lines += _agent_costs(steps[run.id]) or ["  (no steps)"]
    return "\n".join(lines)


async def report(args: argparse.Namespace, session_factory=async_session) -> str:
    async with session_factory() as db:
        if args.cid is not None:
            return await runs_by_correlation(db, args.cid)
        return await runs_of_user(db, args.user, args.last)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="python -m app.cli.runs")
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--cid", help="a correlation ID: that run and its steps")
    which.add_argument("--user", help="an e-mail or user id: that user's last runs")
    parser.add_argument("--last", type=int, default=10, help="how many runs (--user)")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> None:
    args = parse_args(argv)
    try:
        print(asyncio.run(report(args)))
    except RunsError as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
