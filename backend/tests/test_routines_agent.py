"""Asking Echo for a routine: the agent creates, lists and deletes them with its own tools
(no connected app needed), and requests about routines are routed to it."""

import uuid
from datetime import datetime, timezone

import pytest
from sqlalchemy import select

from app.actions import availability
from app.actions.agent import NO_APPS, run_action_agent
from app.models.action_log import ActionLog
from app.models.routine import Routine
from app.services.llm_base import LLMResponse, LLMToolCall
from app.services.routines import MAX_ROUTINES
from tests.conftest import TEST_USER_ID
from tests.mocks import MockLLMService


class _ScriptedLLM(MockLLMService):
    """Returns the scripted responses in order and keeps the tools offered."""

    def __init__(self, responses):
        super().__init__()
        self.tool_responses = list(responses)
        self.tools_log: list[list[dict]] = []

    async def complete_with_tools(self, messages, tools, temperature=0.2):
        self.tools_log.append(tools)
        self.call_log.append(messages)
        return self.tool_responses.pop(0)


def _call(name, **arguments) -> LLMResponse:
    return LLMResponse(content="", model="mock", tool_calls=[LLMToolCall("c1", name, arguments)])


def _text(content) -> LLMResponse:
    return LLMResponse(content=content, model="mock")


async def _run(db, request, llm, **kwargs):
    return await run_action_agent(
        db, TEST_USER_ID, request, [], session_id=None, source="voice", provider=NO_APPS,
        llm=llm, connected_toolkits=[], **kwargs,
    )


async def _routines(db) -> list[Routine]:
    return list(await db.scalars(select(Routine).where(Routine.user_id == TEST_USER_ID)))


async def test_the_agent_creates_a_routine(db_session):
    llm = _ScriptedLLM([
        _call("ECHO_CREATE_ROUTINE", instruction="dimmi che tempo fa a Milano",
              kind="daily", time="07:00"),
        _text("Ogni mattina alle 7:00 ti dirò che tempo fa a Milano."),
    ])

    outcome = await _run(db_session, "ogni mattina alle 7 dimmi che tempo fa a Milano", llm)
    await db_session.commit()

    [routine] = await _routines(db_session)
    assert routine.instruction == "dimmi che tempo fa a Milano"
    assert routine.schedule == {"kind": "daily", "time": "07:00"}
    assert routine.timezone == "Europe/Rome" and routine.active and routine.source == "voice"
    assert outcome.answer.startswith("Ogni mattina")
    # The tool's result told the model when it runs, in words
    tool_message = llm.call_log[-1][-1]
    assert tool_message.role == "tool" and "Every day at 07:00" in tool_message.content
    # Logged like any other action, so it shows in Activity
    log = (await db_session.scalars(select(ActionLog))).one()
    assert log.tool == "ECHO_CREATE_ROUTINE" and log.outcome == "ok"


async def test_routine_tools_are_offered_without_any_app(db_session):
    llm = _ScriptedLLM([_text("ok")])

    await _run(db_session, "ogni lunedì riassumimi le email", llm)

    names = [tool["function"]["name"] for tool in llm.tools_log[0]]
    assert {"ECHO_CREATE_ROUTINE", "ECHO_LIST_ROUTINES", "ECHO_DELETE_ROUTINE"} <= set(names)
    assert "routine" in llm.call_log[0][0].content.lower()


async def test_a_bad_schedule_is_told_to_the_model(db_session):
    llm = _ScriptedLLM([
        _call("ECHO_CREATE_ROUTINE", instruction="x", kind="hourly", time="07:00"),
        _text("Non posso farlo ogni ora."),
    ])

    await _run(db_session, "ogni ora dimmi l'ora", llm)

    assert await _routines(db_session) == []
    assert "daily, weekdays, weekly or monthly" in llm.call_log[-1][-1].content


async def test_at_most_ten(db_session):
    for _ in range(MAX_ROUTINES):
        llm = _ScriptedLLM([
            _call("ECHO_CREATE_ROUTINE", instruction="meteo", kind="daily", time="07:00"),
            _text("ok"),
        ])
        await _run(db_session, "ogni giorno il meteo", llm)
    await db_session.commit()
    llm = _ScriptedLLM([
        _call("ECHO_CREATE_ROUTINE", instruction="meteo", kind="daily", time="08:00"),
        _text("Ne hai già dieci."),
    ])

    await _run(db_session, "ogni giorno il meteo alle 8", llm)

    assert len(await _routines(db_session)) == MAX_ROUTINES
    assert "At most 10 routines" in llm.call_log[-1][-1].content


async def test_list_and_delete(db_session):
    llm = _ScriptedLLM([
        _call("ECHO_CREATE_ROUTINE", instruction="meteo", kind="weekdays", time="07:30"),
        _text("ok"),
    ])
    await _run(db_session, "nei giorni feriali alle 7:30 il meteo", llm)
    await db_session.commit()
    [routine] = await _routines(db_session)

    llm = _ScriptedLLM([
        _call("ECHO_LIST_ROUTINES"),
        _call("ECHO_DELETE_ROUTINE", routine_id=str(routine.id)),
        _text("Fatto, non te lo dirò più."),
    ])
    await _run(db_session, "smetti di dirmi il meteo", llm)
    await db_session.commit()

    listed = llm.call_log[1][-1].content
    assert str(routine.id) in listed and "Weekdays at 07:30" in listed
    assert await _routines(db_session) == []


async def test_another_users_routine_cannot_be_deleted(db_session):
    other = Routine(
        id=uuid.uuid4(), user_id=uuid.uuid4(), instruction="x",
        schedule={"kind": "daily", "time": "07:00"}, timezone="Europe/Rome", active=True,
        next_run_at=datetime.now(timezone.utc),
        source="chat",
    )
    db_session.add(other)
    await db_session.commit()
    llm = _ScriptedLLM([_call("ECHO_DELETE_ROUTINE", routine_id=str(other.id)), _text("no")])

    await _run(db_session, "cancella quell'incarico", llm)
    await db_session.commit()

    assert await db_session.get(Routine, other.id) is not None
    assert "not found" in llm.call_log[-1][-1].content.lower()


async def test_a_routine_run_offers_no_routine_tools(db_session):
    llm = _ScriptedLLM([_text("Sole.")])

    await _run(db_session, "dimmi che tempo fa a Milano", llm, routine_tools=False)

    names = [tool["function"]["name"] for tool in llm.tools_log[0]]
    assert not any(name.startswith("ECHO_") for name in names)


class _IntentLLM(MockLLMService):
    def __init__(self, result):
        super().__init__()
        self.result = result

    async def complete_json(self, messages, temperature=0.1):
        self.call_log.append(messages)
        return self.result


@pytest.mark.parametrize("connected", [[], ["gmail"]])
async def test_routine_requests_are_routed_to_the_agent(connected):
    llm = _IntentLLM({"routine": True, "needs_apps": False, "apps": []})

    route = await availability.route_request(
        llm, "ogni mattina alle 7 dimmi il meteo", [], connected
    )

    assert route.kind == "agent"
    assert "routine" in llm.call_log[0][0].content


def test_routine_wording_reaches_the_intent_check():
    from app.routers.query import might_need_tools

    for request in (
        "ogni mattina alle 7 dimmi il meteo",
        "tutti i giorni alle 8 riassumimi le email",
        "every Friday at 5 tell me my week",
        "smetti di dirmi il meteo la mattina",
        "quali incarichi ho?",
    ):
        assert might_need_tools(request, []), request
