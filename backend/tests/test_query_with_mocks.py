"""Integration tests for the RAG query pipeline with mocked AI services.

These tests exercise the full query endpoint without needing an OpenAI API key
by patching the embedding and LLM service factories.
"""

import uuid
from datetime import datetime, timezone
from unittest.mock import patch

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService, MockLLMService


def _mock_embedding_service():
    return MockEmbeddingService()


def _mock_llm_query_service():
    return MockLLMService()


@pytest.mark.asyncio
@patch("app.routers.query.get_embedding_service", _mock_embedding_service)
@patch("app.routers.query.get_llm_query_service", _mock_llm_query_service)
async def test_query_with_embedded_chunks(
    client: AsyncClient, auth_headers, db_session: AsyncSession
):
    """Test full RAG query with pre-embedded chunks and mocked services."""
    # Setup: create conversation + chunks with embeddings
    conversation_id = uuid.uuid4()
    await db_session.execute(
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
    await db_session.commit()

    # Generate an embedding for the chunk using the same mock
    mock_embed = MockEmbeddingService()
    chunk_text = "Marco mi ha detto di provare il ristorante giapponese vicino all'ufficio."
    embedding = await mock_embed.embed(chunk_text)

    # Insert chunk with embedding
    chunk_id = uuid.uuid4()
    embedding_str = "[" + ",".join(str(f) for f in embedding) + "]"
    await db_session.execute(
        text(
            "INSERT INTO chunks (id, conversation_id, text, token_count, chunk_index, embedding) "
            "VALUES (:id, :conv_id, :text, :tokens, :idx, CAST(:embedding AS vector))"
        ),
        {
            "id": str(chunk_id),
            "conv_id": str(conversation_id),
            "text": chunk_text,
            "tokens": 15,
            "idx": 0,
            "embedding": embedding_str,
        },
    )
    await db_session.commit()

    # Query
    response = await client.post(
        "/api/query",
        headers=auth_headers,
        json={"question": "Cosa mi ha detto Marco?", "top_k": 5},
    )

    assert response.status_code == 200
    data = response.json()
    assert "answer" in data
    assert len(data["answer"]) > 0
    assert "session_id" in data
    # Should have found the chunk
    assert len(data["sources"]) > 0
    assert "Marco" in data["sources"][0]["text"]


@pytest.mark.asyncio
@patch("app.routers.query.get_embedding_service", _mock_embedding_service)
@patch("app.routers.query.get_llm_query_service", _mock_llm_query_service)
async def test_query_follow_up_uses_session(
    client: AsyncClient, auth_headers, db_session: AsyncSession
):
    """Test that follow-up queries reuse the session context."""
    # First query (creates a session)
    response1 = await client.post(
        "/api/query",
        headers=auth_headers,
        json={"question": "Chi è Marco?", "top_k": 5},
    )
    assert response1.status_code == 200
    session_id = response1.json()["session_id"]

    # Follow-up query with session_id
    response2 = await client.post(
        "/api/query",
        headers=auth_headers,
        json={
            "question": "Dimmi di più su di lui",
            "top_k": 5,
            "session_id": session_id,
        },
    )
    assert response2.status_code == 200
    data2 = response2.json()
    # Should reuse the same session
    assert data2["session_id"] == session_id


@pytest.mark.asyncio
@patch("app.routers.query.get_embedding_service", _mock_embedding_service)
@patch("app.routers.query.get_llm_query_service", _mock_llm_query_service)
async def test_query_with_date_filter(
    client: AsyncClient, auth_headers, db_session: AsyncSession
):
    """Test query with explicit date filters."""
    response = await client.post(
        "/api/query",
        headers=auth_headers,
        json={
            "question": "Cosa è successo?",
            "top_k": 5,
            "date_from": "2026-07-20T00:00:00Z",
            "date_to": "2026-07-20T23:59:59Z",
        },
    )
    assert response.status_code == 200
    data = response.json()
    assert data["date_filter"] is not None
    assert "from" in data["date_filter"]
    assert "to" in data["date_filter"]


@pytest.mark.asyncio
@patch("app.routers.query.get_embedding_service", _mock_embedding_service)
@patch("app.routers.query.get_llm_query_service", _mock_llm_query_service)
async def test_query_temporal_extraction(
    client: AsyncClient, auth_headers, db_session: AsyncSession
):
    """Test that Italian temporal expressions are extracted from the question."""
    response = await client.post(
        "/api/query",
        headers=auth_headers,
        json={"question": "Cosa è successo ieri?", "top_k": 5},
    )
    assert response.status_code == 200
    data = response.json()
    # Should have extracted a date filter from "ieri"
    assert data["date_filter"] is not None
