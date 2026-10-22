"""Running routines: each due one runs once, as its user, with no confirm-tier tool; the
answer lands in the user's thread with Echo and the phone is nudged to notify it."""

import asyncio
import json
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.actions.agent import NO_APPS
from app.models.chat_session import ChatSession
from app.models.routine import Routine
from app.services import usage
from app.services.device_commands import DEVICE_COMMANDS_KEY
from app.services.llm_base import LLMResponse, LLMToolCall
from app.workers import routines as worker
from tests.conftest import TEST_USER_ID, test_session
from tests.fakes.action_provider import FakeActionProvider
from tests.fakes.redis import InMemoryRedis
from tests.mocks import MockLLMService

NOW = datetime(2026, 10, 22, 5, 0, tzinfo=timezone.utc)  # 07:00 in Rome


class _LLM(MockLLMService):
    def __init__(self, answer="Oggi a Milano sole, 19 °C.", responses=None, delay=0.0):
        super().__init__()
        self.answer = answer
        self.responses = list(responses or [])
        self.tools_log: list[list[dict]] = []
        self.delay = delay
        self.owners: list = []

    async def complete_with_tools(self, messages, tools, temperature=0.2):
        self.tools_log.append(tools)
        self.call_log.append(messages)
        self.owners.append(usage.usage_owner.get())
        if self.delay:
            await asyncio.sleep(self.delay)
        if self.responses:
            return self.responses.pop(0)
        return LLMResponse(content=self.answer, model="mock")


async def _routine(**values) -> Routine:
    routine = Routine(
        id=uuid.uuid4(),
        user_id=values.get("user_id", TEST_USER_ID),
        instruction=values.get("instruction", "dimmi che tempo fa a Milano"),
        schedule={"kind": "daily", "time": "07:00"},
        timezone="Europe/Rome",
        active=values.get("active", True),
        next_run_at=values.get("next_run_at", NOW),
        source="voice",
    )
    async with test_session() as db:
        db.add(routine)
        await db.commit()
    return routine


async def _run(llm, redis=None, provider=NO_APPS, now=NOW) -> int:
    return await worker.run_due_routines(
        now, session_factory=test_session, redis_client=redis or InMemoryRedis(), llm=llm,
        provider=provider,
    )


async def _reload(routine) -> Routine:
    async with test_session() as db:
        return await db.get(Routine, routine.id)


async def _thread():
    async with test_session() as db:
        # The latest, as the worker picks it (chat sessions outlive a test)
        return (await db.scalars(
            select(ChatSession)
            .where(ChatSession.user_id == TEST_USER_ID, ChatSession.kind == "voice")
            .order_by(ChatSession.updated_at.desc())
        )).first()


async def test_a_due_routine_runs_once_and_is_rescheduled():
    routine = await _routine()
    llm = _LLM()

    assert await _run(llm) == 1
    assert await _run(llm) == 0

    done = await _reload(routine)
    assert done.last_status == "ok" and done.last_answer == "Oggi a Milano sole, 19 °C."
    assert done.last_run_at is not None
    assert done.next_run_at == datetime(2026, 10, 23, 5, 0, tzinfo=timezone.utc)
    assert len(llm.call_log) == 1


async def test_not_due_paused_and_others_are_left_alone():
    await _routine(next_run_at=NOW + timedelta(minutes=1))
    await _routine(active=False)

    assert await _run(_LLM()) == 0


async def test_two_workers_run_it_once():
    await _routine()
    llm = _LLM(delay=0.2)

    counts = await asyncio.gather(_run(llm), _run(llm))

    assert sorted(counts) == [0, 1]
    assert len(llm.call_log) == 1


async def test_a_routine_more_than_two_hours_late_is_skipped():
    routine = await _routine(next_run_at=NOW - timedelta(hours=3))
    llm = _LLM()

    await _run(llm)

    skipped = await _reload(routine)
    assert skipped.last_status == "skipped"
    assert llm.call_log == []
    assert skipped.next_run_at > NOW


async def test_a_late_run_within_two_hours_still_runs():
    routine = await _routine(next_run_at=NOW - timedelta(minutes=90))

    await _run(_LLM())

    assert (await _reload(routine)).last_status == "ok"


async def test_the_answer_lands_in_the_thread_and_nudges_the_phone():
    routine = await _routine()
    redis = InMemoryRedis()

    await _run(_LLM(), redis=redis)

    thread = await _thread()
    asked, answered = thread.messages[-2:]
    assert asked["role"] == "user" and asked["content"] == "dimmi che tempo fa a Milano"
    assert asked["routine_id"] == str(routine.id)
    assert answered["role"] == "assistant" and answered["content"].startswith("Oggi")
    assert answered["routine_id"] == str(routine.id)
    queued = redis.lists[DEVICE_COMMANDS_KEY.format(user_id=TEST_USER_ID)]
    assert [json.loads(item)["type"] for item in queued] == ["voice_update"]


async def test_no_confirm_or_routine_tools_in_a_routine():
    await _routine()
    provider = FakeActionProvider(
        connected={"gmail"},
        tools={
            name: {"type": "function", "function": {"name": name, "parameters": {}}}
            for name in ("GMAIL_FETCH_EMAILS", "GMAIL_SEND_EMAIL")
        },
    )
    llm = _LLM(responses=[
        # Asked anyway: refused, never a pending action
        LLMResponse(content="", model="mock", tool_calls=[
            LLMToolCall("c1", "GMAIL_SEND_EMAIL", {"to": "ada@example.com"}),
        ]),
        LLMResponse(content="Non posso inviare email da un incarico.", model="mock"),
    ])

    await _run(llm, provider=provider)

    names = {tool["function"]["name"] for tool in llm.tools_log[0]}
    assert "GMAIL_FETCH_EMAILS" in names
    assert "GMAIL_SEND_EMAIL" not in names
    assert not any(name.startswith("ECHO_") for name in names)
    assert provider.executed == []
    assert "confirm" in llm.call_log[-1][-1].content.lower()
    async with test_session() as db:
        from app.models.pending_action import PendingAction

        assert (await db.scalars(select(PendingAction))).all() == []


async def test_a_failing_run_is_reported_and_rescheduled():
    class _Broken(_LLM):
        async def complete_with_tools(self, messages, tools, temperature=0.2):
            raise RuntimeError("model down")

    routine = await _routine()

    await _run(_Broken())

    failed = await _reload(routine)
    assert failed.last_status == "failed"
    assert failed.next_run_at > NOW
    answer = (await _thread()).messages[-1]
    assert answer["role"] == "assistant" and "non" in answer["content"].lower()


async def test_usage_is_owned_by_the_routines_user():
    await _routine()
    llm = _LLM()

    await _run(llm)

    assert llm.owners == [TEST_USER_ID]
