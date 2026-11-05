"""Answers that search the web: the tool is offered while the user is under the cap, the
prompt says to search and cite, and the pages cited reach the answer and the history but
never the memory."""

import uuid
from datetime import datetime, timezone
from unittest.mock import patch

import pytest
from sqlalchemy import func, select, text

from app.actions.agent import run_action_agent
from app.core.config import settings
from app.models.llm_usage import LlmUsage
from app.services.llm_base import LLMResponse
from app.services.memory_answers import rag_system_prompt
from app.workers import voice_requests as vr
from tests.conftest import TEST_USER_ID, test_session
from tests.mocks import MockEmbeddingService, MockLLMService

PAGES = [
    {"title": "Meteo Milano", "url": "https://www.ilmeteo.it/meteo/Milano"},
    {"title": None, "url": "https://3bmeteo.com/milano"},
]


class _SearchingLLM(MockLLMService):
    """A model that can search: remembers the hosted tools offered, cites PAGES when
    it gets the search tool."""

    can_search = True

    def __init__(self, answer="Domani a Milano sole, secondo ilmeteo.it."):
        super().__init__(default_response=answer)
        self.hosted: list = []

    async def complete(self, messages, temperature=0.3, hosted_tools=None):
        self.call_log.append(messages)
        self.hosted.append(hosted_tools)
        return LLMResponse(
            content=self.default_response, model="mock",
            citations=list(PAGES) if hosted_tools else [],
        )

    async def stream(self, messages, temperature=0.3, hosted_tools=None, on_citations=None):
        self.call_log.append(messages)
        self.hosted.append(hosted_tools)
        yield "Domani "
        yield "sole."
        if hosted_tools and on_citations:
            on_citations(list(PAGES))

    async def complete_with_tools(self, messages, tools, temperature=0.2, hosted_tools=None):
        self.hosted.append(hosted_tools)
        return LLMResponse(
            content="Ecco il meteo.", model="mock",
            citations=list(PAGES) if hosted_tools else [],
        )


@pytest.fixture(autouse=True)
def _openai_search(monkeypatch):
    monkeypatch.setattr(settings, "web_search_provider", "openai")
    monkeypatch.setattr(settings, "plans", {"free": {"web_searches_per_day": 30}})


def _patched(llm):
    return (
        patch("app.routers.query.get_embedding_service", MockEmbeddingService),
        patch("app.routers.query.get_llm_query_service", lambda: llm),
    )


async def _at_the_cap():
    async with test_session() as db:
        db.add(LlmUsage(
            id=uuid.uuid4(), user_id=TEST_USER_ID, day=datetime.now(timezone.utc).date(),
            kind="web_search", model="openai-web-search", calls=1, input_units=30,
        ))
        await db.commit()


def test_the_prompt_says_to_search_only_when_it_can():
    about = "Echo is a wearable."
    searching = rag_system_prompt(None, about, can_search=True)
    not_searching = rag_system_prompt(None, about)

    assert "search the web" in searching and "cannot see live information" not in searching
    assert "name the sources" in searching
    assert "cannot see live information" in not_searching


async def test_a_question_offers_the_search_tool(client, auth_headers):
    llm = _SearchingLLM()
    first, second = _patched(llm)
    with first, second:
        response = await client.post(
            "/api/query", headers=auth_headers,
            json={"question": "che tempo fa domani a Milano?"},
        )

    assert response.status_code == 200
    assert llm.hosted[-1][0]["type"] == "web_search"
    assert "search the web" in llm.call_log[-1][0].content
    assert response.json()["web_sources"] == PAGES


async def test_at_the_cap_no_tool_and_the_old_rule(client, auth_headers):
    await _at_the_cap()
    llm = _SearchingLLM()
    first, second = _patched(llm)
    with first, second:
        response = await client.post(
            "/api/query", headers=auth_headers,
            json={"question": "che tempo fa domani a Milano?"},
        )

    assert llm.hosted[-1] is None
    assert "cannot see live information" in llm.call_log[-1][0].content
    assert response.json()["web_sources"] == []


async def test_web_sources_are_kept_in_the_history(client, auth_headers):
    llm = _SearchingLLM()
    first, second = _patched(llm)
    with first, second:
        response = await client.post(
            "/api/query", headers=auth_headers,
            json={"question": "che tempo fa domani a Milano?"},
        )
    session_id = response.json()["session_id"]

    detail = await client.get(f"/api/chat-sessions/{session_id}", headers=auth_headers)

    answer = detail.json()["messages"][-1]
    assert answer["role"] == "assistant"
    assert answer["citations"] == PAGES


async def test_the_stream_done_event_carries_web_sources(client, auth_headers):
    from tests.test_query_stream import _events

    llm = _SearchingLLM()
    first, second = _patched(llm)
    with first, second:
        response = await client.post(
            "/api/query/stream", headers=auth_headers,
            json={"question": "che tempo fa domani a Milano?"},
        )

    events = _events(response.text)
    assert [kind for kind, _ in events] == ["token", "token", "done"]
    assert events[-1][1]["answer"] == "Domani sole."
    assert events[-1][1]["web_sources"] == PAGES


async def test_web_text_never_becomes_memory(client, auth_headers, db_session):
    async def count(table):
        return await db_session.scalar(text(f"SELECT count(*) FROM {table}"))

    before = (await count("entities"), await count("chunks"), await count("conversations"))
    llm = _SearchingLLM()
    first, second = _patched(llm)
    with first, second:
        await client.post(
            "/api/query", headers=auth_headers,
            json={"question": "che tempo fa domani a Milano?"},
        )

    after = (await count("entities"), await count("chunks"), await count("conversations"))
    assert after == before


async def test_voice_answers_offer_the_tool(monkeypatch, db_session):
    async def no_memory(db, user_id, question, **kw):
        from types import SimpleNamespace

        return SimpleNamespace(context="", sources=[], date_range=None)

    monkeypatch.setattr(vr, "retrieve_memory_context", no_memory)
    monkeypatch.setattr(vr, "get_embedding_service", lambda: None)
    llm = _SearchingLLM()

    answer = await vr._memory_answer(
        db_session, TEST_USER_ID, "che tempo fa domani a Milano?", [], llm, about="Echo."
    )

    assert answer == "Domani a Milano sole, secondo ilmeteo.it."
    assert llm.hosted[-1][0]["type"] == "web_search"


async def test_the_agent_offers_the_tool_and_returns_the_pages(db_session):
    from tests.fakes.action_provider import FakeActionProvider

    llm = _SearchingLLM()
    outcome = await run_action_agent(
        db_session, TEST_USER_ID, "che tempo fa domani a Milano?", [],
        session_id=None, source="chat", provider=FakeActionProvider(), llm=llm,
        connected_toolkits=[],
    )

    assert llm.hosted[-1][0]["type"] == "web_search"
    assert outcome.web_sources == PAGES


async def test_a_model_that_cannot_search_gets_no_tool(client, auth_headers, db_session):
    llm = MockLLMService(default_response="Non posso vedere il meteo.")
    first, second = _patched(llm)
    with first, second:
        response = await client.post(
            "/api/query", headers=auth_headers,
            json={"question": "che tempo fa domani a Milano?"},
        )

    assert response.status_code == 200
    assert response.json()["web_sources"] == []
    searches = await db_session.scalar(
        select(func.count()).select_from(LlmUsage).where(LlmUsage.kind == "web_search")
    )
    assert searches == 0


def test_memory_answers_offer_charts_only_when_asked():
    from app.services.memory_answers import rag_system_prompt

    assert "```echo-chart" in rag_system_prompt(None, visuals=True)
    assert "echo-chart" not in rag_system_prompt(None)
