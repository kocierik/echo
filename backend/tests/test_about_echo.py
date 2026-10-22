"""Questions about Echo itself, general ones and live ones: the memory prompt knows what
Echo is, and an empty memory still asks the model instead of a fixed text."""

import json
from unittest.mock import patch

import pytest

from app.actions.phone_provider import set_phone_apps
from app.services.about_echo import about_echo
from app.services.memory_answers import _NO_RESULTS, rag_system_prompt
from app.workers import voice_requests as vr
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService, MockLLMService


class _BrokenLLM(MockLLMService):
    async def complete(self, messages, temperature=0.3):
        raise RuntimeError("model down")

    async def stream(self, messages, temperature=0.3):
        raise RuntimeError("model down")
        yield ""  # pragma: no cover - makes this an async generator


class _StreamingLLM(MockLLMService):
    async def stream(self, messages, temperature=0.3):
        self.call_log.append(messages)
        for piece in ["Ricordo ", "le tue conversazioni."]:
            yield piece


def _events(body: str) -> list[tuple[str, dict]]:
    events = []
    for block in body.strip().split("\n\n"):
        lines = dict(line.split(": ", 1) for line in block.splitlines())
        events.append((lines["event"], json.loads(lines["data"])))
    return events


def test_the_memory_prompt_knows_what_echo_is():
    prompt = rag_system_prompt(None, about_echo(["applecalendar"]))

    assert "About Echo" in prompt
    assert "What Echo can do" in prompt
    assert "Profile → Apps" in prompt
    # The apps Echo works with, and the phone's apps that are on
    assert "Gmail" in prompt and "Google Calendar" in prompt
    assert "Phone Calendar" in prompt and "Phone Reminders" not in prompt
    # The four kinds of question it may meet
    assert "general knowledge" in prompt
    assert "never guess" in prompt
    assert "live information" in prompt
    # Labels as the English app shows them; the answer in the question's language, last
    assert "never a translation" in prompt
    assert prompt.rstrip().endswith("in another language.")


def test_without_phone_apps_the_phone_is_not_offered():
    assert "Phone Calendar" not in about_echo([])


@pytest.mark.asyncio
async def test_an_empty_memory_asks_the_model_instead_of_a_fixed_text(client, auth_headers):
    llm = MockLLMService(default_response="Ricordo le tue conversazioni e rispondo.")
    with (
        patch("app.routers.query.get_embedding_service", MockEmbeddingService),
        patch("app.routers.query.get_llm_query_service", lambda: llm),
    ):
        response = await client.post(
            "/api/query", headers=auth_headers, json={"question": "cosa sai fare?"}
        )

    assert response.status_code == 200
    assert response.json()["answer"] == "Ricordo le tue conversazioni e rispondo."
    system = llm.call_log[-1][0]
    assert system.role == "system" and "About Echo" in system.content
    assert "Context from memory" not in llm.call_log[-1][-1].content


@pytest.mark.asyncio
async def test_the_phone_apps_that_are_on_reach_the_prompt(client, auth_headers):
    await set_phone_apps(client._transport.app.state.redis, TEST_USER_ID, ["applecalendar"])
    llm = MockLLMService()
    with (
        patch("app.routers.query.get_embedding_service", MockEmbeddingService),
        patch("app.routers.query.get_llm_query_service", lambda: llm),
    ):
        await client.post("/api/query", headers=auth_headers, json={"question": "cosa sai fare?"})

    assert "Phone Calendar" in llm.call_log[-1][0].content


@pytest.mark.asyncio
async def test_a_failing_model_falls_back_to_the_fixed_text(client, auth_headers):
    with (
        patch("app.routers.query.get_embedding_service", MockEmbeddingService),
        patch("app.routers.query.get_llm_query_service", _BrokenLLM),
    ):
        response = await client.post(
            "/api/query", headers=auth_headers, json={"question": "cosa sai fare?"}
        )

    assert response.json()["answer"] == _NO_RESULTS["it"]


@pytest.mark.asyncio
async def test_the_stream_answers_from_the_model_too(client, auth_headers):
    with (
        patch("app.routers.query.get_embedding_service", MockEmbeddingService),
        patch("app.routers.query.get_llm_query_service", _StreamingLLM),
    ):
        response = await client.post(
            "/api/query/stream", headers=auth_headers, json={"question": "cosa sai fare?"}
        )

    events = _events(response.text)
    assert [kind for kind, _ in events] == ["token", "token", "done"]
    assert events[-1][1]["answer"] == "Ricordo le tue conversazioni."
    assert events[-1][1]["sources"] == []


@pytest.mark.asyncio
async def test_voice_requests_use_the_same_rules(monkeypatch, db_session):
    async def no_memory(db, user_id, question, **kw):
        from types import SimpleNamespace

        return SimpleNamespace(context="", sources=[], date_range=None)

    monkeypatch.setattr(vr, "retrieve_memory_context", no_memory)
    monkeypatch.setattr(vr, "get_embedding_service", lambda: None)
    llm = MockLLMService(default_response="Posso ricordare e agire nelle tue app.")

    answer = await vr._memory_answer(
        db_session, TEST_USER_ID, "cosa sai fare?", [], llm, about=about_echo([])
    )

    assert answer == "Posso ricordare e agire nelle tue app."
    assert "About Echo" in llm.call_log[-1][0].content


@pytest.mark.asyncio
async def test_voice_falls_back_to_the_fixed_text_when_the_model_fails(monkeypatch, db_session):
    async def no_memory(db, user_id, question, **kw):
        from types import SimpleNamespace

        return SimpleNamespace(context="", sources=[], date_range=None)

    monkeypatch.setattr(vr, "retrieve_memory_context", no_memory)
    monkeypatch.setattr(vr, "get_embedding_service", lambda: None)

    answer = await vr._memory_answer(
        db_session, TEST_USER_ID, "cosa sai fare?", [], _BrokenLLM(), about=""
    )

    assert answer == _NO_RESULTS["it"]



def test_a_clear_question_language_is_spelled_out():
    from app.services.language import clear_language

    assert clear_language("When does Ada want to launch Atlas?") == "en"
    assert clear_language("Quando vuole lanciare Atlas Ada?") == "it"
    # Too little to tell: the model follows the question by itself
    assert clear_language("ciao") is None
    assert clear_language("Marco?") is None
    prompt = rag_system_prompt(None, about_echo([]), language="en")
    assert prompt.rstrip().endswith("The question is in English: answer in English.")
    assert "The question is in" not in rag_system_prompt(None, about_echo([]))
