"""Running routines: each due one runs once, as its user, with no confirm-tier tool; each
run is recorded (never in the thread), and the phone is nudged only when a run has
something to say or failed."""

import asyncio
import json
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from sqlalchemy import select

from app.actions.agent import NO_APPS
from app.models.chat_session import ChatSession
from app.models.routine import Routine
from app.models.routine_run import RoutineRun
from app.services import usage
from app.services.device_commands import DEVICE_COMMANDS_KEY
from app.services.llm_base import LLMResponse, LLMToolCall
from app.services.routine_results import compose_text, item_key
from app.workers import routines as worker
from tests.conftest import TEST_USER_ID, test_session
from tests.fakes.action_provider import FakeActionProvider
from tests.fakes.redis import InMemoryRedis
from tests.mocks import MockLLMService

NOW = datetime(2026, 10, 22, 5, 0, tzinfo=timezone.utc)  # 07:00 in Rome


class _LLM(MockLLMService):
    def __init__(
        self, answer="Oggi a Milano sole, 19 °C.", responses=None, delay=0.0, conversions=None
    ):
        super().__init__()
        self.answer = answer
        self.responses = list(responses or [])
        # What the one conversion call (llm.complete) answers, in order
        self.conversions = list(conversions or [])
        self.complete_log: list = []
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

    async def complete(self, messages, temperature=0.3):
        self.complete_log.append(messages)
        content = self.conversions.pop(0) if self.conversions else ""
        return LLMResponse(content=content, model="mock")


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
        mode=values.get("mode", "always"),
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


async def _runs(routine) -> list[RoutineRun]:
    async with test_session() as db:
        return list(
            await db.scalars(
                select(RoutineRun)
                .where(RoutineRun.routine_id == routine.id)
                .order_by(RoutineRun.ran_at)
            )
        )


def _nudges(redis) -> list[str]:
    queued = redis.lists.get(DEVICE_COMMANDS_KEY.format(user_id=TEST_USER_ID), [])
    return [json.loads(item)["type"] for item in queued]


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
    assert done.last_status == "reported" and done.last_answer == "Oggi a Milano sole, 19 °C."
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


async def test_a_late_routine_records_a_skipped_run():
    routine = await _routine(next_run_at=NOW - timedelta(hours=3))
    redis = InMemoryRedis()

    await _run(_LLM(), redis=redis)

    [run] = await _runs(routine)
    assert (run.status, run.text, run.ran_at) == ("skipped", None, NOW - timedelta(hours=3))
    assert _nudges(redis) == []


async def test_a_late_run_within_two_hours_still_runs():
    routine = await _routine(next_run_at=NOW - timedelta(minutes=90))

    await _run(_LLM())

    assert (await _reload(routine)).last_status == "reported"


async def test_an_always_routine_reports_its_answer_as_a_run_not_in_the_thread():
    routine = await _routine()
    redis = InMemoryRedis()

    await _run(_LLM(), redis=redis)

    [run] = await _runs(routine)
    assert (run.status, run.text, run.user_id) == (
        "reported",
        "Oggi a Milano sole, 19 °C.",
        TEST_USER_ID,
    )
    assert run.sources == [] and run.items == []
    thread = await _thread()
    assert thread is None or not any(m.get("routine_id") for m in thread.messages or [])
    assert (await _reload(routine)).last_status == "reported"
    assert _nudges(redis) == ["voice_update"]


async def test_the_agent_gets_an_always_instruction_unchanged():
    await _routine()
    llm = _LLM()

    await _run(llm)

    assert llm.call_log[0][-1].content == "dimmi che tempo fa a Milano"


async def test_web_sources_are_kept_with_the_run(monkeypatch):
    routine = await _routine()
    pages = [{"title": "Meteo", "url": "https://meteo.it"}]

    async def _agent(*args, **kwargs):
        return SimpleNamespace(answer="Sole.", web_sources=pages)

    monkeypatch.setattr(worker, "run_action_agent", _agent)

    await _run(_LLM())

    [run] = await _runs(routine)
    assert (run.text, run.sources) == ("Sole.", pages)


async def test_only_if_that_does_not_hold_is_nothing_and_not_nudged():
    routine = await _routine(mode="only_if", instruction="dimmi se piove domani")
    redis = InMemoryRedis()
    llm = _LLM(answer='{"report": false, "intro": "", "text": "", "items": []}')

    await _run(llm, redis=redis)

    [run] = await _runs(routine)
    assert (run.status, run.text) == ("nothing", None)
    assert _nudges(redis) == []
    done = await _reload(routine)
    assert done.last_status == "nothing" and done.last_run_at is not None
    assert '"report"' in llm.call_log[0][-1].content


async def test_only_if_that_holds_reports_its_text():
    routine = await _routine(mode="only_if", instruction="dimmi se piove domani")
    redis = InMemoryRedis()
    llm = _LLM(answer='{"report": true, "intro": "", "text": "Domani piove dalle 15"}')

    await _run(llm, redis=redis)

    [run] = await _runs(routine)
    assert (run.status, run.text) == ("reported", "Domani piove dalle 15")
    assert (await _reload(routine)).last_answer == "Domani piove dalle 15"
    assert _nudges(redis) == ["voice_update"]



async def test_only_if_that_holds_with_no_text_says_so_not_the_raw_json():
    routine = await _routine(mode="only_if", instruction="dimmi se piove domani")
    redis = InMemoryRedis()
    llm = _LLM(answer='{"report": true, "intro": "", "text": "", "items": []}')

    await _run(llm, redis=redis)

    [run] = await _runs(routine)
    assert run.status == "reported"
    assert "{" not in run.text
    assert "dimmi se piove domani" in run.text
    assert _nudges(redis) == ["voice_update"]


def _jobs(*urls) -> str:
    return json.dumps(
        {
            "report": True,
            "intro": "Nuove posizioni:",
            "text": "",
            "items": [{"title": f"Job {u[-1]}", "line": "Milano", "url": u} for u in urls],
        }
    )


async def _seen_run(routine, url: str) -> None:
    async with test_session() as db:
        db.add(
            RoutineRun(
                routine_id=routine.id,
                user_id=TEST_USER_ID,
                ran_at=NOW - timedelta(days=1),
                status="reported",
                text="old",
                items=[{"key": item_key({"url": url}), "title": "Job 1", "url": url}],
            )
        )
        await db.commit()


async def test_only_new_reports_only_items_not_seen_before():
    routine = await _routine(mode="only_new", instruction="nuove posizioni backend")
    await _seen_run(routine, "https://x.io/1")
    redis = InMemoryRedis()

    await _run(_LLM(answer=_jobs("http://x.io/1/?utm=a", "https://x.io/2")), redis=redis)

    run = (await _runs(routine))[-1]
    fresh = {"title": "Job 2", "line": "Milano", "url": "https://x.io/2"}
    assert run.status == "reported"
    assert run.text == compose_text("Nuove posizioni:", [fresh])
    assert [item["key"] for item in run.items] == ["https://x.io/2"]
    assert _nudges(redis) == ["voice_update"]



async def test_only_new_keeps_no_source_for_what_it_already_reported(monkeypatch):
    routine = await _routine(mode="only_new", instruction="nuove posizioni backend")
    await _seen_run(routine, "https://x.io/1")
    pages = [
        {"title": "Job 1", "url": "https://www.x.io/1/"},
        {"title": "Job 2", "url": "https://x.io/2"},
    ]

    async def _agent(*args, **kwargs):
        return SimpleNamespace(
            answer=_jobs("https://x.io/1", "https://x.io/2"), web_sources=pages
        )

    monkeypatch.setattr(worker, "run_action_agent", _agent)

    await _run(_LLM())

    run = (await _runs(routine))[-1]
    assert run.sources == [{"title": "Job 2", "url": "https://x.io/2"}]


async def test_only_new_with_only_seen_items_is_nothing_and_not_nudged():
    routine = await _routine(mode="only_new", instruction="nuove posizioni backend")
    await _seen_run(routine, "https://x.io/1")
    redis = InMemoryRedis()

    await _run(_LLM(answer=_jobs("https://x.io/1")), redis=redis)

    run = (await _runs(routine))[-1]
    assert (run.status, run.text, run.items) == ("nothing", None, [])
    assert _nudges(redis) == []


async def test_only_new_tells_the_agent_what_it_already_reported():
    routine = await _routine(mode="only_new", instruction="nuove posizioni backend")
    await _seen_run(routine, "https://x.io/1")
    llm = _LLM(answer=_jobs())

    await _run(llm)

    request = llm.call_log[0][-1].content
    assert request.startswith("nuove posizioni backend") and "Job 1" in request


async def test_an_unreadable_answer_is_converted_once_then_reported_raw():
    routine = await _routine(mode="only_if", instruction="dimmi se piove domani")
    llm = _LLM(answer="Piove domani", conversions=["Non so"])

    await _run(llm)

    [run] = await _runs(routine)
    assert (run.status, run.text) == ("reported", "Piove domani")
    assert len(llm.complete_log) == 1
    assert llm.complete_log[0][-1].content == "Piove domani"


async def test_a_converted_answer_is_used():
    routine = await _routine(mode="only_if", instruction="dimmi se piove domani")
    redis = InMemoryRedis()
    llm = _LLM(answer="Domani niente pioggia", conversions=['{"report": false}'])

    await _run(llm, redis=redis)

    [run] = await _runs(routine)
    assert run.status == "nothing"
    assert _nudges(redis) == []


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


async def test_a_failed_run_is_recorded_and_nudged():
    class _Broken(_LLM):
        async def complete_with_tools(self, messages, tools, temperature=0.2):
            raise RuntimeError("model down")

    routine = await _routine()
    redis = InMemoryRedis()

    await _run(_Broken(), redis=redis)

    [run] = await _runs(routine)
    assert (run.status, run.text) == ("failed", worker.FAILED["it"])
    assert _nudges(redis) == ["voice_update"]


async def test_usage_is_owned_by_the_routines_user():
    await _routine()
    llm = _LLM()

    await _run(llm)

    assert llm.owners == [TEST_USER_ID]


async def test_only_new_filters_with_every_item_ever_reported():
    routine = await _routine(mode="only_new", instruction="nuove posizioni backend")
    async with test_session() as db:
        for day in range(3):
            db.add(
                RoutineRun(
                    routine_id=routine.id,
                    user_id=TEST_USER_ID,
                    ran_at=NOW - timedelta(days=day + 1),
                    status="reported",
                    items=[
                        {"key": item_key({"url": f"https://x.io/{day}-{i}"}), "title": "t",
                         "url": None}
                        for i in range(100)
                    ],
                )
            )
        await db.commit()

    # The oldest of 300 openings, past the 200 the request lists
    await _run(_LLM(answer=_jobs("https://x.io/2-99")))

    run = (await _runs(routine))[-1]
    assert run.status == "nothing"


async def test_only_new_with_its_findings_in_text_but_no_items_reports_the_text():
    routine = await _routine(mode="only_new", instruction="nuove posizioni backend")
    answer = json.dumps(
        {"report": True, "intro": "", "text": "Backend Engineer da Satispay", "items": []}
    )

    await _run(_LLM(answer=answer))

    [run] = await _runs(routine)
    assert (run.status, run.text) == ("reported", "Backend Engineer da Satispay")


async def test_the_agent_speaks_the_instruction_s_language(monkeypatch):
    await _routine(mode="only_if", instruction="dimmi se piove domani")
    seen = []

    async def _agent(*args, **kwargs):
        seen.append(kwargs.get("language"))
        return SimpleNamespace(answer='{"report": false}', web_sources=[])

    monkeypatch.setattr(worker, "run_action_agent", _agent)

    await _run(_LLM())

    assert seen == ["it"]


async def test_an_agent_that_could_not_answer_is_a_failed_run(monkeypatch):
    from app.actions.agent import TEXTS

    routine = await _routine(mode="only_if", instruction="dimmi se piove domani")
    redis = InMemoryRedis()

    async def _agent(*args, **kwargs):
        return SimpleNamespace(answer=TEXTS["it"]["unreachable"], web_sources=[])

    monkeypatch.setattr(worker, "run_action_agent", _agent)

    await _run(_LLM(), redis=redis)

    [run] = await _runs(routine)
    assert run.status == "failed"
    assert _nudges(redis) == ["voice_update"]


async def test_one_routine_crashing_does_not_stop_the_others(monkeypatch):
    broken = await _routine(mode="only_new", next_run_at=NOW - timedelta(minutes=1))
    fine = await _routine()

    async def _boom(*args, **kwargs):
        raise RuntimeError("database gone")

    monkeypatch.setattr(worker, "seen_keys", _boom)

    await _run(_LLM())

    assert [r.status for r in await _runs(fine)] == ["reported"]
    assert [r.status for r in await _runs(broken)] == ["failed"]
