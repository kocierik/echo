"""The cap of one request: how many steps, how many tokens and how much time it may use.

The coordinator opens a cap with `start_budget` when a request starts; it lives in a
ContextVar, so the child tasks the request starts share it (the same object). Before
every model call and every tool call the caller asks `check()`:

- `ok`: it charges the step (`charge_step`) and goes on;
- `deadline_passed`: it does not start the call and ends with `timeout`;
- `tokens_exhausted` / `steps_exhausted`: it does not start the call and ends with
  `budget_exceeded`.

The limits are checked in that order: deadline, tokens, steps. A call already started
always finishes and its tokens are charged (services/usage.record_usage charges every
language-model call), so a request overruns its cap by one call at most.

Outside a request that opened a cap (routines, workers, today's endpoints) nothing here
has any effect: `check()` is `ok` and charges change nothing. The deadline uses the
monotonic clock, never the wall clock. This module imports nothing from the app
(tests/test_core_imports.py).
"""

import time
import uuid
from contextvars import ContextVar
from dataclasses import dataclass
from typing import Literal

CheckResult = Literal["ok", "steps_exhausted", "tokens_exhausted", "deadline_passed"]


@dataclass
class RequestLimits:
    """The cap of the current request; mutable, shared with its child tasks."""

    max_steps: int
    max_tokens: int
    # time.monotonic() when the request must stop starting new calls
    deadline: float
    used_steps: int = 0
    used_tokens: int = 0
    run_id: uuid.UUID | None = None


current_budget_var: ContextVar[RequestLimits | None] = ContextVar(
    "current_budget", default=None
)


def current_budget() -> RequestLimits | None:
    """The cap of the current request, or None outside one."""
    return current_budget_var.get()


def start_budget(
    max_steps: int,
    max_tokens: int,
    timeout_seconds: float,
    run_id: uuid.UUID | None = None,
) -> RequestLimits:
    """Open the cap of the current request and make it the current one."""
    if max_steps < 1 or max_tokens < 1 or timeout_seconds <= 0:
        raise ValueError("A request cap needs at least one step, one token and some time")
    limits = RequestLimits(
        max_steps=max_steps,
        max_tokens=max_tokens,
        deadline=time.monotonic() + timeout_seconds,
        run_id=run_id,
    )
    current_budget_var.set(limits)
    return limits


def charge_tokens(tokens: int) -> None:
    """Add a finished model call's tokens to the current cap (none: no effect)."""
    limits = current_budget_var.get()
    if limits is not None and tokens > 0:
        limits.used_tokens += tokens


def charge_step() -> None:
    """Count one model or tool call against the current cap (none: no effect)."""
    limits = current_budget_var.get()
    if limits is not None:
        limits.used_steps += 1


def check() -> CheckResult:
    """The first limit the current request has reached (deadline, tokens, steps), or ok."""
    limits = current_budget_var.get()
    if limits is None:
        return "ok"
    if time.monotonic() >= limits.deadline:
        return "deadline_passed"
    if limits.used_tokens >= limits.max_tokens:
        return "tokens_exhausted"
    if limits.used_steps >= limits.max_steps:
        return "steps_exhausted"
    return "ok"
