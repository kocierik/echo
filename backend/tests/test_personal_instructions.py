"""The user's own instructions ("call me Erik, keep it short") and name reach every answer:
chat, voice, the agent and photos; they never change what needs the user's Confirm."""

import uuid
from unittest.mock import patch

from sqlalchemy import text

from app.actions.agent import NO_APPS, run_action_agent
from app.services.memory_answers import rag_system_prompt
from app.services.personal import MAX_INSTRUCTIONS, personal_context
from app.workers import voice_requests as vr
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService, MockLLMService
from tests.test_routines_agent import _ScriptedLLM, _text

INSTRUCTIONS = "Rispondimi sempre in breve. Il lavoro è su Slack."


async def _account(db, name="Erik", instructions=INSTRUCTIONS):
    await db.execute(
        text(
            "INSERT INTO users (id, email, password_hash, language, name, instructions, "
            "created_at) VALUES (:id, :email, 'x', 'it', :name, :instructions, now())"
        ),
        {"id": str(TEST_USER_ID), "email": f"{uuid.uuid4()}@x.io", "name": name,
         "instructions": instructions},
    )
    await db.commit()


async def test_the_context_names_the_user_and_quotes_the_instructions(db_session):
    await _account(db_session)

    context = await personal_context(db_session, TEST_USER_ID)

    assert "Erik" in context and INSTRUCTIONS in context
    assert "Confirm" in context


async def test_no_account_or_nothing_set_gives_nothing(db_session):
    assert await personal_context(db_session, TEST_USER_ID) == ""
    await _account(db_session, name=None, instructions=None)
    assert await personal_context(db_session, TEST_USER_ID) == ""


async def test_the_memory_prompt_puts_them_before_the_language_rule():
    prompt = rag_system_prompt(None, "Echo is a wearable.", "it", personal="PERSONAL")

    assert "PERSONAL" in prompt
    assert prompt.index("PERSONAL") < prompt.index("The question is in Italian")


async def test_me_reads_and_sets_the_instructions(client, auth_headers, db_session):
    await _account(db_session, instructions=None)

    response = await client.patch(
        "/api/auth/me", headers=auth_headers, json={"instructions": f"  {INSTRUCTIONS}  "}
    )
    assert response.status_code == 200
    assert response.json()["instructions"] == INSTRUCTIONS
    me = await client.get("/api/auth/me", headers=auth_headers)
    assert me.json()["instructions"] == INSTRUCTIONS
    # The other fields are kept
    assert me.json()["name"] == "Erik"

    cleared = await client.patch("/api/auth/me", headers=auth_headers, json={"instructions": ""})
    assert cleared.json()["instructions"] is None

    too_long = await client.patch(
        "/api/auth/me", headers=auth_headers,
        json={"instructions": "x" * (MAX_INSTRUCTIONS + 1)},
    )
    assert too_long.status_code == 422


async def test_chat_answers_follow_them(client, auth_headers, db_session):
    await _account(db_session)
    llm = MockLLMService(default_response="Ok.")
    with (
        patch("app.routers.query.get_embedding_service", MockEmbeddingService),
        patch("app.routers.query.get_llm_query_service", lambda: llm),
    ):
        await client.post("/api/query", headers=auth_headers, json={"question": "cosa sai fare?"})

    assert INSTRUCTIONS in llm.call_log[-1][0].content


async def test_voice_answers_follow_them(monkeypatch, db_session):
    await _account(db_session)

    async def no_memory(db, user_id, question, **kw):
        from types import SimpleNamespace

        return SimpleNamespace(context="", sources=[], date_range=None)

    monkeypatch.setattr(vr, "retrieve_memory_context", no_memory)
    monkeypatch.setattr(vr, "get_embedding_service", lambda: None)
    llm = MockLLMService(default_response="Ok.")

    await vr._memory_answer(db_session, TEST_USER_ID, "cosa sai fare?", [], llm, about="Echo.")

    assert INSTRUCTIONS in llm.call_log[-1][0].content


async def test_the_agent_follows_them(db_session):
    await _account(db_session)
    llm = _ScriptedLLM([_text("Ok.")])

    await run_action_agent(
        db_session, TEST_USER_ID, "riassumimi le email", [], session_id=None, source="chat",
        provider=NO_APPS, llm=llm, connected_toolkits=[],
    )

    system = llm.call_log[0][0].content
    assert INSTRUCTIONS in system and "Erik" in system


def test_photo_answers_follow_them_but_not_the_memory_description():
    from types import SimpleNamespace

    from app.services.photos import _vision_messages

    photo = SimpleNamespace(question="cosa c'è scritto?", user_id=TEST_USER_ID)
    with patch("app.services.photos.message_language", lambda photo: "it"):
        system = _vision_messages(photo, b"jpeg", personal=INSTRUCTIONS)[0].content

    assert system.endswith(f"For the answer only:\n{INSTRUCTIONS}")
