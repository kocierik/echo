"""A to-do asked of Echo with no app named goes to Echo's own list (Today → To do)."""

import pytest
from sqlalchemy import select

from app.actions import availability
from app.actions.agent import NO_APPS, run_action_agent
from app.models.entity import Entity
from app.services.llm_base import LLMResponse, LLMToolCall
from tests.conftest import TEST_USER_ID
from tests.test_routines_agent import _IntentLLM, _ScriptedLLM, _text


def _call(tool, **arguments) -> LLMResponse:
    return LLMResponse(content="", model="mock", tool_calls=[LLMToolCall("c1", tool, arguments)])


async def _run(db, request, llm):
    return await run_action_agent(
        db, TEST_USER_ID, request, [], session_id=None, source="voice", provider=NO_APPS,
        llm=llm, connected_toolkits=[],
    )


async def _tasks(db) -> list[Entity]:
    return list(await db.scalars(
        select(Entity).where(Entity.user_id == TEST_USER_ID, Entity.entity_type == "task")
    ))


async def test_the_agent_adds_a_to_do_to_echos_list(db_session):
    llm = _ScriptedLLM([
        _call("ECHO_CREATE_TASK", name="Comprare il latte", due_date="2026-10-23"),
        _text("Segnato: comprare il latte, per domani."),
    ])

    await _run(db_session, "segnami di comprare il latte per domani", llm)
    await db_session.commit()

    [task] = await _tasks(db_session)
    assert task.name == "Comprare il latte"
    assert task.metadata_ == {"done": False, "asked": True, "due_date": "2026-10-23"}
    assert "To-dos and reminders" in llm.call_log[0][0].content
    names = {tool["function"]["name"] for tool in llm.tools_log[0]}
    assert "ECHO_CREATE_TASK" in names


async def test_a_bad_date_is_told_to_the_model(db_session):
    llm = _ScriptedLLM([
        _call("ECHO_CREATE_TASK", name="Pagare la bolletta", due_date="lunedì"),
        _text("Per quale giorno?"),
    ])

    await _run(db_session, "segnami di pagare la bolletta lunedì", llm)

    assert await _tasks(db_session) == []
    assert "YYYY-MM-DD" in llm.call_log[-1][-1].content


@pytest.mark.parametrize("connected", [[], ["todoist"]])
async def test_a_to_do_with_no_app_named_goes_to_the_agent(connected):
    llm = _IntentLLM({"todo": True, "needs_apps": False, "apps": []})

    route = await availability.route_request(llm, "segnami di comprare il latte", [], connected)

    assert route.kind == "agent"
    # Echo's own tools are enough: no connected app's tools go along (they did, all of
    # them, ~14,000 tokens a request)
    assert route.apps == []
    assert '"todo"' in llm.call_log[0][0].content


async def test_a_to_do_for_a_named_app_still_needs_that_app():
    llm = _IntentLLM({"todo": True, "needs_apps": True, "apps": ["todoist"]})

    route = await availability.route_request(llm, "aggiungi su Todoist il latte", [], [])

    # Todoist is not connected: said so, not put in Echo's list
    assert route.kind == "notice"
