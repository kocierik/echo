"""POST /api/query/stream: a memory answer arrives in pieces, then the full response."""

import asyncio
import json
import uuid
from datetime import datetime, timezone
from unittest.mock import patch

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.services.llm_base import LLMResponse
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService, MockLLMService

PIECES = ["Marco ", "suggested ", "the Japanese place."]


class _StreamingLLM(MockLLMService):
    """Writes the answer in three pieces."""

    async def stream(self, messages, temperature=0.3):
        for piece in PIECES:
            yield piece


class _FailingLLM(MockLLMService):
    async def stream(self, messages, temperature=0.3):
        yield "Half an"
        raise RuntimeError("model went away")

    async def complete(self, messages, temperature=0.3):
        return LLMResponse(content="Recovered answer.", model="mock")


class _SlowLLM(_StreamingLLM):
    """Thinks for a while before the first piece (an agent, a web search)."""

    async def stream(self, messages, temperature=0.3):
        await asyncio.sleep(0.2)
        for piece in PIECES:
            yield piece


def _events(body: str) -> list[tuple[str, dict]]:
    """The events, without the comments that keep the connection alive."""
    events = []
    for block in body.strip().split("\n\n"):
        if block.startswith(":"):
            continue
        lines = dict(line.split(": ", 1) for line in block.splitlines())
        events.append((lines["event"], json.loads(lines["data"])))
    return events


async def _memory_about_marco(db: AsyncSession) -> None:
    conversation_id = uuid.uuid4()
    await db.execute(
        text(
            "INSERT INTO conversations (id, user_id, started_at, analysis_status) "
            "VALUES (:id, :user_id, :started_at, 'completed')"
        ),
        {
            "id": str(conversation_id),
            "user_id": str(TEST_USER_ID),
            "started_at": datetime.now(timezone.utc),
        },
    )
    chunk = "Marco mi ha detto di provare il ristorante giapponese vicino all'ufficio."
    embedding = await MockEmbeddingService().embed(chunk)
    await db.execute(
        text(
            "INSERT INTO chunks (id, conversation_id, text, token_count, chunk_index, embedding) "
            "VALUES (:id, :conv_id, :text, 15, 0, CAST(:embedding AS vector))"
        ),
        {
            "id": str(uuid.uuid4()),
            "conv_id": str(conversation_id),
            "text": chunk,
            "embedding": "[" + ",".join(str(f) for f in embedding) + "]",
        },
    )
    await db.commit()


def _patched(llm_class):
    return [
        patch("app.routers.query.get_embedding_service", MockEmbeddingService),
        patch("app.routers.query.get_llm_query_service", llm_class),
    ]


@pytest.mark.asyncio
async def test_a_memory_answer_streams_then_completes(client, auth_headers, db_session):
    await _memory_about_marco(db_session)
    with _patched(_StreamingLLM)[0], _patched(_StreamingLLM)[1]:
        response = await client.post(
            "/api/query/stream",
            headers=auth_headers,
            json={"question": "Cosa mi ha detto Marco?"},
        )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")
    events = _events(response.text)
    assert [kind for kind, _ in events] == ["token", "token", "token", "done"]
    assert [data["text"] for kind, data in events if kind == "token"] == PIECES
    done = events[-1][1]
    assert done["answer"] == "".join(PIECES)
    assert done["sources"] and "Marco" in done["sources"][0]["text"]
    assert "started_at" in done["sources"][0] and "title" in done["sources"][0]

    # The turn is saved like any chat
    sessions = (await client.get("/api/chat-sessions", headers=auth_headers)).json()["items"]
    saved = next(s for s in sessions if s["id"] == done["session_id"])
    assert saved["message_count"] == 2


@pytest.mark.asyncio
async def test_without_memory_the_model_still_answers_in_pieces(client, auth_headers):
    # It may be a question about Echo or a general one (test_about_echo.py)
    with _patched(_StreamingLLM)[0], _patched(_StreamingLLM)[1]:
        response = await client.post(
            "/api/query/stream", headers=auth_headers, json={"question": "Cosa ho fatto ieri?"}
        )

    events = _events(response.text)
    assert [kind for kind, _ in events] == ["token", "token", "token", "done"]
    assert events[-1][1]["answer"] == "".join(PIECES)
    assert events[-1][1]["sources"] == []


@pytest.mark.asyncio
async def test_a_slow_answer_keeps_the_connection_alive(client, auth_headers):
    # The phone gives up after a stretch with nothing on the wire, while the server
    # goes on: its retry then got 409 "Still working on it"
    with (
        _patched(_SlowLLM)[0],
        _patched(_SlowLLM)[1],
        patch("app.routers.query.HEARTBEAT_SECONDS", 0.05),
    ):
        response = await client.post(
            "/api/query/stream", headers=auth_headers, json={"question": "Che tempo fa?"}
        )

    blocks = response.text.strip().split("\n\n")
    # Something at once, then something while the answer is still being worked on
    assert blocks[0].startswith(":")
    assert sum(block.startswith(":") for block in blocks) >= 3
    events = _events(response.text)
    assert [kind for kind, _ in events] == ["token", "token", "token", "done"]
    assert events[-1][1]["answer"] == "".join(PIECES)


@pytest.mark.asyncio
async def test_a_retry_replays_the_stored_answer(client, auth_headers, db_session):
    await _memory_about_marco(db_session)
    body = {"question": "Cosa mi ha detto Marco?", "client_request_id": "req-1"}
    with _patched(_StreamingLLM)[0], _patched(_StreamingLLM)[1]:
        first = await client.post("/api/query/stream", headers=auth_headers, json=body)
        second = await client.post("/api/query/stream", headers=auth_headers, json=body)

    replay = _events(second.text)
    assert [kind for kind, _ in replay] == ["done"]
    assert replay[0][1]["answer"] == _events(first.text)[-1][1]["answer"]


@pytest.mark.asyncio
async def test_a_running_request_is_409_before_streaming(client, auth_headers):
    redis = client._transport.app.state.redis
    await redis.set(f"query:req:{TEST_USER_ID}:req-2", "processing")

    response = await client.post(
        "/api/query/stream",
        headers=auth_headers,
        json={"question": "Ciao", "client_request_id": "req-2"},
    )

    assert response.status_code == 409


@pytest.mark.asyncio
async def test_a_model_failure_is_an_error_event_and_the_retry_can_run(
    client, auth_headers, db_session
):
    await _memory_about_marco(db_session)
    body = {"question": "Cosa mi ha detto Marco?", "client_request_id": "req-3"}
    with _patched(_FailingLLM)[0], _patched(_FailingLLM)[1]:
        response = await client.post("/api/query/stream", headers=auth_headers, json=body)

    events = _events(response.text)
    assert events[0] == ("token", {"text": "Half an"})
    assert events[-1][0] == "error"
    assert events[-1][1]["status"] == 500
    # Nothing ran on other apps: the marker is gone, so the same message can be retried
    redis = client._transport.app.state.redis
    assert await redis.get(f"query:req:{TEST_USER_ID}:req-3") is None
