"""Ask's one thread with Echo: the voice session, shared by typed and voice requests."""

import uuid
from datetime import datetime, timezone
from unittest.mock import patch

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ChatSession
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService, MockLLMService

LLM = MockLLMService(default_response="Domani piove.")


async def _thread(client: AsyncClient, auth_headers) -> dict:
    response = await client.get("/api/chat-sessions/thread", headers=auth_headers)
    assert response.status_code == 200
    return response.json()


async def _stored(db: AsyncSession, session_id) -> ChatSession:
    return (
        await db.execute(
            select(ChatSession)
            .where(ChatSession.id == uuid.UUID(str(session_id)))
            .execution_options(populate_existing=True)
        )
    ).scalar_one()


async def _ask(client, auth_headers, question, session_id):
    with (
        patch("app.routers.query.get_embedding_service", MockEmbeddingService),
        patch("app.routers.query.get_llm_query_service", lambda: LLM),
    ):
        response = await client.post(
            "/api/query",
            headers=auth_headers,
            json={"question": question, "session_id": session_id},
        )
    assert response.status_code == 200
    return response.json()


@pytest.mark.asyncio
async def test_thread_endpoint_creates_once_and_returns_the_voice_session(
    client, auth_headers, db_session
):
    first = await _thread(client, auth_headers)
    again = await _thread(client, auth_headers)

    assert first["id"] == again["id"]
    assert first["title"] == "Echo" and first["kind"] == "voice"
    assert first["messages"] == []
    sessions = (
        await db_session.execute(select(ChatSession).where(ChatSession.user_id == TEST_USER_ID))
    ).scalars().all()
    assert len(sessions) == 1


@pytest.mark.asyncio
async def test_a_typed_question_in_the_thread_sees_voice_turns(
    client, auth_headers, db_session
):
    thread = await _thread(client, auth_headers)
    stored = await _stored(db_session, thread["id"])
    now = datetime.now(timezone.utc).isoformat()
    # A voice turn, written by the voice worker straight into Postgres
    stored.messages = [
        {"role": "user", "content": "che tempo fa a Milano?", "timestamp": now, "source": "voice"},
        {"role": "assistant", "content": "Sole, 21 gradi.", "timestamp": now},
    ]
    await db_session.commit()
    LLM.call_log.clear()

    await _ask(client, auth_headers, "e domani?", thread["id"])
    await _ask(client, auth_headers, "e dopodomani?", thread["id"])

    seen = [m.content for m in LLM.call_log[0]]
    assert "che tempo fa a Milano?" in seen and "Sole, 21 gradi." in seen
    # The second question saw each earlier turn once (Postgres, not Postgres + Redis)
    second = [m.content for m in LLM.call_log[-1]]
    assert second.count("e domani?") == 1 and second.count("che tempo fa a Milano?") == 1
    messages = (await _thread(client, auth_headers))["messages"]
    assert [m["content"] for m in messages] == [
        "che tempo fa a Milano?", "Sole, 21 gradi.",
        "e domani?", "Domani piove.", "e dopodomani?", "Domani piove.",
    ]
    assert messages[2]["source"] == "chat" and messages[2]["timestamp"]
    assert messages[0]["source"] == "voice"
    raw = (await _stored(db_session, thread["id"])).messages
    # A typed answer is shown where it was asked: never notified
    assert raw[3]["notify"] is False and raw[3]["timestamp"]


@pytest.mark.asyncio
async def test_typed_answers_in_the_thread_are_not_voice_updates(
    client, auth_headers, db_session
):
    thread = await _thread(client, auth_headers)
    await _ask(client, auth_headers, "ciao?", thread["id"])

    updates = await client.get("/api/actions/voice-updates", headers=auth_headers)

    assert updates.json()["messages"] == []


@pytest.mark.asyncio
async def test_legacy_messages_without_source_or_time_load(client, auth_headers, db_session):
    thread = await _thread(client, auth_headers)
    stored = await _stored(db_session, thread["id"])
    stored.messages = [
        {"role": "user", "content": "Echo, che ore sono?"},
        {"role": "assistant", "content": "Le 10."},
    ]
    await db_session.commit()

    messages = (await _thread(client, auth_headers))["messages"]

    assert [(m["source"], m["timestamp"]) for m in messages] == [(None, None), (None, None)]


@pytest.mark.asyncio
async def test_a_new_chat_stays_its_own_session(client, auth_headers):
    thread = await _thread(client, auth_headers)

    answer = await _ask(client, auth_headers, "una chat a parte", None)

    assert answer["session_id"] != thread["id"]
    assert (await _thread(client, auth_headers))["messages"] == []
