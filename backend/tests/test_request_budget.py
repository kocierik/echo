"""The cap of one request (core/request_budget.py): steps, tokens and a deadline.

Every test is async: each runs in its own task, so the cap it opens never reaches
another test. The deadline is moved by replacing the module's monotonic clock.
"""

import asyncio
import contextvars

import pytest

from app.core import request_budget
from app.core.request_budget import (
    charge_step,
    charge_tokens,
    check,
    current_budget,
    start_budget,
)


class _Clock:
    def __init__(self, now: float = 1000.0):
        self.now = now

    def monotonic(self) -> float:
        return self.now


@pytest.fixture
def clock(monkeypatch):
    fake = _Clock()
    monkeypatch.setattr(request_budget.time, "monotonic", fake.monotonic)
    return fake


async def test_without_a_cap_check_is_ok_and_charges_change_nothing():
    assert current_budget() is None
    charge_tokens(10_000_000)
    charge_step()

    assert check() == "ok" and current_budget() is None


async def test_each_limit_is_reported_when_reached(clock):
    limits = start_budget(max_steps=3, max_tokens=1000, timeout_seconds=45)
    assert current_budget() is limits and limits.deadline == 1045.0
    assert check() == "ok"

    charge_tokens(999)
    assert check() == "ok"
    charge_tokens(1)
    assert check() == "tokens_exhausted"

    start_budget(max_steps=2, max_tokens=1000, timeout_seconds=45)
    charge_step()
    assert check() == "ok"
    charge_step()
    assert check() == "steps_exhausted"

    start_budget(max_steps=2, max_tokens=1000, timeout_seconds=45)
    clock.now += 44.9
    assert check() == "ok"
    clock.now += 0.1
    assert check() == "deadline_passed"


async def test_the_order_is_deadline_then_tokens_then_steps(clock):
    start_budget(max_steps=1, max_tokens=10, timeout_seconds=5)
    charge_step()
    assert check() == "steps_exhausted"
    charge_tokens(10)
    assert check() == "tokens_exhausted"
    clock.now += 5
    assert check() == "deadline_passed"


async def test_a_call_already_started_is_charged_whole_and_the_next_check_stops(clock):
    limits = start_budget(max_steps=10, max_tokens=1000, timeout_seconds=45)
    charge_tokens(900)

    assert check() == "ok"  # the call may start...
    charge_step()
    charge_tokens(700)  # ...and its tokens count even past the cap

    assert limits.used_tokens == 1600
    assert check() == "tokens_exhausted"


async def test_child_tasks_share_the_cap_of_their_request(clock):
    limits = start_budget(max_steps=10, max_tokens=10_000, timeout_seconds=45)

    async def agent(tokens):
        assert check() == "ok"
        charge_step()
        await asyncio.sleep(0)
        charge_tokens(tokens)

    await asyncio.gather(*(asyncio.create_task(agent(t)) for t in (100, 200, 300)))

    assert (limits.used_steps, limits.used_tokens) == (3, 600)


async def test_work_outside_the_request_does_not_see_its_cap(clock):
    start_budget(max_steps=1, max_tokens=1, timeout_seconds=1)
    charge_step()
    assert check() == "steps_exhausted"

    # A worker or routine task, started from its own context
    outside = asyncio.create_task(_check_now(), context=contextvars.Context())
    assert await outside == "ok"


async def _check_now() -> str:
    return check()


async def test_a_cap_needs_a_step_a_token_and_some_time():
    for args in ((0, 10, 5), (1, 0, 5), (1, 10, 0)):
        with pytest.raises(ValueError):
            start_budget(*args)
    assert current_budget() is None


async def test_negative_or_zero_tokens_are_not_charged(clock):
    limits = start_budget(max_steps=5, max_tokens=100, timeout_seconds=5)
    charge_tokens(0)
    charge_tokens(-50)

    assert limits.used_tokens == 0
