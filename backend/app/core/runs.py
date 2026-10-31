"""Run tracking: what each coordinator request or routine run did, step by step.

A *run* is one piece of new work (a chat or voice request the coordinator handles, a
routine's run) and its *steps* are what it did: a plan, a delegation, a model call, a
tool call, a synthesis. Both go to `agent_runs` / `agent_steps` (models/agent_run.py)
and `make runs` shows them (cli/runs.py).

The current run lives in a ContextVar, like `usage_owner`: `open_run` (or `run_scope`)
sets it, `record_step` adds to it, `close_run` ends it. Child tasks made with
`asyncio.create_task` inherit it and add to the same RunContext. The agent working right
now is a ContextVar of its own (`agent_scope`), so two agents running side by side each
name their own steps.

Tracking never gets in the way of the work it measures:

- with `run_tracking_enabled` off (the default) nothing is written: `open_run` returns a
  RunContext without a `run_id`, and every other call does nothing;
- every write uses its own session and commit, so it survives the request's rollback;
- a failed write is logged with the run id and the error's class (never its message,
  which may hold values) and the work goes on.

The cost of a step is an estimate from app/usage_prices.py; a model without a price
leaves the cost at 0 and marks it `cost_unknown`, never silently free. Tool arguments
are stored reduced to their shape (core/redaction.py). This module never imports the
actions, services, agents or workers packages (tests/test_core_imports.py).
"""

import asyncio
import contextlib
import logging
import re
import uuid
from collections.abc import AsyncIterator, Iterator
from contextvars import ContextVar
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from sqlalchemy import delete, update
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from app.core.config import settings
from app.core.database import get_session_factory
from app.core.logging import correlation_id as correlation_id_var
from app.core.logging import new_correlation_id
from app.core.redaction import redact_for_tracking
from app.models.agent_run import (
    RUN_SOURCES,
    RUN_STATUSES,
    STEP_KINDS,
    STEP_STATUSES,
    AgentRun,
    AgentStep,
)
from app.usage_prices import PRICES

logger = logging.getLogger(__name__)

_COST_PLACES = Decimal("0.000001")
_PLAN_SUMMARY_MAX = 200
_ERROR_CLASS_MAX = 64
# An agent id as the registry names them ("memory", "actions", "routines.daily")
_AGENT_ID = re.compile(r"^[a-z][a-z0-9_.-]{0,39}$")


@dataclass
class RunContext:
    """The run of the current task; mutable, shared with the child tasks it starts."""

    correlation_id: str
    source: str
    user_id: uuid.UUID | None = None
    # None when tracking is off or the first write failed: nothing is written for it
    run_id: uuid.UUID | None = None
    next_seq: int = 1
    tokens_in: int = 0
    tokens_out: int = 0
    cost_usd: Decimal = field(default_factory=Decimal)
    cost_unknown: bool = False
    closed: bool = False

    @property
    def current_agent(self) -> str | None:
        """The agent working in this task (`agent_scope`), named on its model calls."""
        return current_agent_var.get()


current_run_var: ContextVar[RunContext | None] = ContextVar("current_run", default=None)
current_agent_var: ContextVar[str | None] = ContextVar("current_agent", default=None)


def current_run() -> RunContext | None:
    """The run of the current task, or None outside one."""
    return current_run_var.get()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _log_failure(operation: str, run: RunContext | None, exc: BaseException) -> None:
    """A tracking write failed: the class of the error only, never its message (D3)."""
    logger.warning(
        "Run tracking write failed (%s)",
        operation,
        extra={
            "run_id": run.run_id if run is not None else None,
            "error_class": type(exc).__name__,
        },
    )


def step_cost(
    model: str | None, tokens_in: int, tokens_out: int, tokens_cached: int = 0
) -> tuple[Decimal, bool]:
    """Estimated USD of a model call and whether its price is unknown.

    Cached input tokens (part of `tokens_in`) use the model's cached price when there is
    one, else the input price. No tokens: free and known (a tool call).
    """
    if not (tokens_in or tokens_out):
        return Decimal(0), False
    price = PRICES.get(model or "")
    if price is None or price.get("unit") != "token":
        return Decimal(0), True
    cached = min(max(tokens_cached, 0), tokens_in)
    fresh = tokens_in - cached
    usd = (
        fresh * price["input"]
        + cached * price.get("cached", price["input"])
        + tokens_out * price["output"]
    ) / 1_000_000
    return Decimal(repr(usd)).quantize(_COST_PLACES), False


def _plan_summary(summary) -> str | None:
    """Only agent ids, comma-separated: anything else (the model's text) is dropped."""
    if summary is None:
        return None
    parts = summary.split(",") if isinstance(summary, str) else list(summary)
    ids = [str(p).strip() for p in parts if _AGENT_ID.match(str(p).strip())]
    kept = ""
    for agent in ids:
        candidate = f"{kept},{agent}" if kept else agent
        if len(candidate) > _PLAN_SUMMARY_MAX:
            break
        kept = candidate
    return kept or None


async def open_run(
    user_id: uuid.UUID | None, source: str, correlation_id: str | None = None
) -> RunContext:
    """Start a run for new work and make it the current one.

    The correlation ID defaults to the request's (a new one when there is none). Never
    raises for a failed write: the RunContext then has no `run_id` and nothing more is
    written for it.
    """
    if source not in RUN_SOURCES:
        raise ValueError(f"Unknown run source: {source}")
    cid = correlation_id or correlation_id_var.get() or new_correlation_id()
    if not correlation_id_var.get():
        correlation_id_var.set(cid)
    run = RunContext(correlation_id=cid, source=source, user_id=user_id)
    current_run_var.set(run)
    if not settings.run_tracking_enabled:
        return run

    run_id = uuid.uuid4()
    try:
        async with get_session_factory()() as db:
            db.add(AgentRun(
                id=run_id,
                correlation_id=cid,
                user_id=user_id,
                source=source,
                status="running",
                started_at=_now(),
            ))
            await db.commit()
        run.run_id = run_id
    except Exception as exc:
        _log_failure("open_run", run, exc)
    return run


async def record_step(
    kind: str,
    *,
    agent_id: str | None = None,
    tool_name: str | None = None,
    tier: str | None = None,
    status: str = "ok",
    duration_ms: int = 0,
    tokens_in: int = 0,
    tokens_out: int = 0,
    tokens_cached: int = 0,
    model: str | None = None,
    attempt: int = 1,
    error_class: str | None = None,
    args: dict | None = None,
    action_log_id: uuid.UUID | None = None,
) -> None:
    """Add a step to the current run. Outside a tracked run it does nothing; never raises.

    `args` (tool calls) are stored reduced to their shape; `tokens_cached` is the part of
    `tokens_in` the provider served from its cache (it only changes the cost).
    """
    run = current_run_var.get()
    if run is None or run.run_id is None or run.closed:
        return
    try:
        if kind not in STEP_KINDS or status not in STEP_STATUSES:
            raise ValueError(f"Unknown step kind or status: {kind}, {status}")
        # The number is taken before any await: concurrent tasks never share one
        seq = run.next_seq
        run.next_seq += 1
        duration_ms = max(int(duration_ms or 0), 0)
        tokens_in, tokens_out = max(int(tokens_in or 0), 0), max(int(tokens_out or 0), 0)
        cost, unknown = step_cost(model, tokens_in, tokens_out, int(tokens_cached or 0))
        run.tokens_in += tokens_in
        run.tokens_out += tokens_out
        run.cost_usd += cost
        run.cost_unknown = run.cost_unknown or unknown
        step = AgentStep(
            run_id=run.run_id,
            seq=seq,
            kind=kind,
            agent_id=agent_id[:80] if agent_id else None,
            tool_name=tool_name[:120] if tool_name else None,
            model=model[:80] if model else None,
            tier=tier,
            attempt=max(int(attempt or 1), 1),
            started_at=_now() - timedelta(milliseconds=duration_ms),
            duration_ms=duration_ms,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            cost_usd=cost,
            cost_unknown=unknown,
            status=status,
            error_class=error_class[:_ERROR_CLASS_MAX] if error_class else None,
            args_redacted=redact_for_tracking(args) if args is not None else None,
            action_log_id=action_log_id,
        )
        async with get_session_factory()() as db:
            db.add(step)
            await db.commit()
    except Exception as exc:
        _log_failure("record_step", run, exc)


async def close_run(
    run: RunContext | None,
    status: str,
    plan_summary=None,
    error_class: str | None = None,
) -> None:
    """End a run with its final status, totals and plan (agent ids only).

    A run ends once: closing it again leaves the first status and logs a warning.
    """
    if status not in RUN_STATUSES or status == "running":
        raise ValueError(f"Not a final run status: {status}")
    if run is None:
        return
    if run.closed:
        logger.warning("Run already closed, %s ignored", status, extra={"run_id": run.run_id})
        return
    run.closed = True
    if run.run_id is None:
        return
    try:
        async with get_session_factory()() as db:
            result = await db.execute(
                update(AgentRun)
                .where(AgentRun.id == run.run_id, AgentRun.status == "running")
                .values(
                    status=status,
                    ended_at=_now(),
                    tokens_in=run.tokens_in,
                    tokens_out=run.tokens_out,
                    cost_usd=run.cost_usd,
                    cost_unknown=run.cost_unknown,
                    plan_summary=_plan_summary(plan_summary),
                    error_class=error_class[:_ERROR_CLASS_MAX] if error_class else None,
                )
            )
            await db.commit()
        if result.rowcount == 0:
            logger.warning(
                "Run no longer running, %s ignored", status, extra={"run_id": run.run_id}
            )
    except Exception as exc:
        _log_failure("close_run", run, exc)


@contextlib.asynccontextmanager
async def run_scope(
    user_id: uuid.UUID | None, source: str, correlation_id: str | None = None
) -> AsyncIterator[RunContext]:
    """A run for the block: `completed` when it ends normally (unless the block already
    closed it, e.g. with `timeout`), `failed` with the exception's class when it raises,
    `failed` / `cancelled` when the task is cancelled. The exception always propagates."""
    previous = current_run_var.get()
    run = await open_run(user_id, source, correlation_id)
    try:
        yield run
    except asyncio.CancelledError:
        if not run.closed:
            await close_run(run, "failed", error_class="cancelled")
        raise
    except BaseException as exc:
        if not run.closed:
            await close_run(run, "failed", error_class=type(exc).__name__)
        raise
    else:
        if not run.closed:
            await close_run(run, "completed")
    finally:
        current_run_var.set(previous)


@contextlib.contextmanager
def agent_scope(agent_id: str) -> Iterator[None]:
    """The steps recorded inside the block (model calls too) belong to `agent_id`."""
    token = current_agent_var.set(agent_id)
    try:
        yield
    finally:
        current_agent_var.reset(token)


async def close_interrupted(older_than_seconds: int, session_factory=None) -> int:
    """Close as `interrupted` the runs still `running` after `older_than_seconds`: their
    process stopped (a restart, a crash) before closing them. Idempotent, never raises;
    returns how many were closed."""
    now = _now()
    try:
        async with (session_factory or get_session_factory())() as db:
            result = await db.execute(
                update(AgentRun)
                .where(
                    AgentRun.status == "running",
                    AgentRun.started_at < now - timedelta(seconds=older_than_seconds),
                )
                .values(status="interrupted", ended_at=now, error_class="interrupted")
            )
            await db.commit()
    except Exception as exc:
        _log_failure("close_interrupted", None, exc)
        return 0
    closed = result.rowcount or 0
    if closed:
        logger.info("Closed %s interrupted run(s)", closed)
    return closed


async def purge_older_than(days: int) -> int:
    """Delete the runs started more than `days` days ago; their steps go with them
    (ON DELETE CASCADE). Returns how many runs were deleted; errors reach the caller."""
    async with get_session_factory()() as db:
        result = await db.execute(
            delete(AgentRun).where(AgentRun.started_at < _now() - timedelta(days=days))
        )
        await db.commit()
    return result.rowcount or 0


# The whole-request timeout (NFR2). The coordinator (U4) brings its own setting; until
# then the startup check uses this value
DEFAULT_REQUEST_TIMEOUT_S = 45


async def startup_close_interrupted(
    request_timeout_seconds: float = DEFAULT_REQUEST_TIMEOUT_S,
) -> int:
    """At the start of api and worker: warn about a threshold too low for the request
    timeout, then close the runs a previous process left `running`. Never raises.

    It uses one connection of its own, closed at once, never the shared pool: a startup
    hook may run on another event loop than the requests (Starlette's TestClient runs the
    lifespan in its own thread), and a pooled connection bound to that loop would break
    the next session that takes it.
    """
    warning = interrupted_threshold_warning(request_timeout_seconds)
    if warning:
        logger.warning(warning)
    engine = create_async_engine(settings.database_url, poolclass=NullPool)
    try:
        return await close_interrupted(
            settings.run_interrupted_after_seconds,
            session_factory=async_sessionmaker(engine, expire_on_commit=False),
        )
    finally:
        await engine.dispose()


def interrupted_threshold_warning(request_timeout_seconds: float) -> str | None:
    """The warning to log at startup when the interrupted threshold could close runs
    that are still alive: below the request timeout plus 85 s, a request that ran its
    longest tool and a model call already started after the deadline may still be
    working (BR2.2)."""
    floor = request_timeout_seconds + 85
    if settings.run_interrupted_after_seconds < floor:
        return (
            f"run_interrupted_after_seconds={settings.run_interrupted_after_seconds} is "
            f"below {floor:g} s (request timeout {request_timeout_seconds:g} s + 85 s): "
            "live runs may be closed as interrupted"
        )
    return None
