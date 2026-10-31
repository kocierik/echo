"""Every language-model call is charged to the request's cap and is a step of its run.

services/usage.record_usage is the one place every model call passes through: there an
`llm_*` call adds its tokens to the cap (core/request_budget.py) and an `llm_call` step to
the current run (core/runs.py), before and apart from the `llm_usage` write.
"""

import asyncio
from types import SimpleNamespace

import pytest
from sqlalchemy import func, select

from app.core import runs
from app.core.config import settings
from app.core.request_budget import current_budget, start_budget
from app.models import AgentStep, LlmUsage
from app.services import llm_openai, usage
from app.services.llm_base import LLMMessage
from app.services.usage import owned_by, record_usage
from tests.conftest import TEST_USER_ID, test_session

ns = SimpleNamespace


@pytest.fixture
def tracking(monkeypatch):
    monkeypatch.setattr(settings, "run_tracking_enabled", True)


class _Broken:
    async def __aenter__(self):
        raise RuntimeError("database down")

    async def __aexit__(self, *exc):
        return False


async def _steps() -> list[AgentStep]:
    async with test_session() as db:
        return (await db.scalars(select(AgentStep).order_by(AgentStep.seq))).all()


async def _usage_rows() -> int:
    async with test_session() as db:
        return await db.scalar(select(func.count()).select_from(LlmUsage))


async def test_a_model_call_is_charged_and_recorded_as_a_step_of_its_agent(tracking):
    await runs.open_run(TEST_USER_ID, "chat", "cid-hook")
    limits = start_budget(max_steps=10, max_tokens=10_000, timeout_seconds=45)

    with owned_by(TEST_USER_ID), runs.agent_scope("memory"):
        await record_usage(
            "llm_query", "gpt-6-luna", input_units=100, output_units=20, cached_units=40,
            duration_ms=321, attempt=2, session_factory=test_session,
        )

    assert limits.used_tokens == 120
    [step] = await _steps()
    assert (step.kind, step.agent_id, step.model) == ("llm_call", "memory", "gpt-6-luna")
    assert (step.tokens_in, step.tokens_out, step.duration_ms, step.attempt) == (100, 20, 321, 2)
    assert await _usage_rows() == 1  # today's usage row, as before


@pytest.mark.parametrize("kind", ["embedding", "stt", "voice", "web_search"])
async def test_other_kinds_of_work_are_neither_charged_nor_steps(tracking, kind):
    await runs.open_run(TEST_USER_ID, "chat", "cid-other")
    limits = start_budget(max_steps=10, max_tokens=10_000, timeout_seconds=45)

    await record_usage(kind, "m", input_units=500, session_factory=test_session)

    assert limits.used_tokens == 0
    assert await _steps() == []


async def test_a_failed_usage_write_still_charges_and_records_the_step(tracking):
    await runs.open_run(TEST_USER_ID, "chat", "cid-broken")
    limits = start_budget(max_steps=10, max_tokens=10_000, timeout_seconds=45)

    await record_usage("llm_intent", "gpt-6-luna", input_units=50, output_units=5,
                       session_factory=_Broken)

    assert limits.used_tokens == 55
    [step] = await _steps()
    assert (step.duration_ms, step.attempt, step.agent_id) == (0, 1, None)


async def test_a_failing_step_never_stops_the_usage_write(tracking, monkeypatch):
    async def failing_step(*args, **kwargs):
        raise RuntimeError("tracking down")

    monkeypatch.setattr(usage, "record_step", failing_step)
    await runs.open_run(TEST_USER_ID, "chat", "cid-step-fails")
    limits = start_budget(max_steps=10, max_tokens=10_000, timeout_seconds=45)

    await record_usage("llm_query", "m", input_units=7, session_factory=test_session)

    assert limits.used_tokens == 7
    assert await _usage_rows() == 1


async def test_outside_a_request_the_usage_write_is_unchanged():
    assert current_budget() is None and runs.current_run() is None

    with owned_by(TEST_USER_ID):
        await record_usage("llm_query", "m", input_units=3, session_factory=test_session)

    assert await _usage_rows() == 1
    assert await _steps() == []


async def test_the_llm_layer_passes_the_duration_of_each_call(monkeypatch):
    calls = []

    async def record(kind, model, **kwargs):
        calls.append((kind, kwargs.get("duration_ms")))

    async def create(**kwargs):
        await asyncio.sleep(0.02)
        return ns(
            choices=[ns(message=ns(content="ok", tool_calls=None))], model="m",
            usage=ns(prompt_tokens=10, completion_tokens=2, total_tokens=12,
                     prompt_tokens_details=ns(cached_tokens=0)),
        )

    monkeypatch.setattr(llm_openai, "record_usage", record)
    service = llm_openai.OpenAILLMService("m", kind="llm_query")
    service.client = ns(chat=ns(completions=ns(create=create)))

    await service.complete([LLMMessage(role="user", content="ciao")])

    [(kind, duration_ms)] = calls
    assert kind == "llm_query" and isinstance(duration_ms, int) and duration_ms >= 20
