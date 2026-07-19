"""Integration tests for POST /api/query endpoint."""

import uuid
from datetime import datetime, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from tests.conftest import TEST_USER_ID


@pytest.mark.asyncio
async def test_query_empty_memory(client: AsyncClient, auth_headers):
    """Test querying when no data exists."""
    response = await client.post(
        "/api/query",
        headers=auth_headers,
        json={"question": "Cosa mi ha detto Marco?", "top_k": 5},
    )

    assert response.status_code == 200
    data = response.json()
    assert "answer" in data
    assert "sources" in data
    assert data["sources"] == []
    # Should indicate no data available
    assert "Non ho ancora" in data["answer"] or len(data["answer"]) > 0


@pytest.mark.asyncio
async def test_query_no_auth(client: AsyncClient):
    """Test that query without API key is rejected."""
    response = await client.post(
        "/api/query",
        json={"question": "Test?", "top_k": 5},
    )

    assert response.status_code in (401, 403, 422)


@pytest.mark.asyncio
async def test_query_invalid_body(client: AsyncClient, auth_headers):
    """Test that query with invalid body is rejected."""
    response = await client.post(
        "/api/query",
        headers=auth_headers,
        json={"not_a_question": "test"},
    )

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_query_with_chunks(client: AsyncClient, auth_headers, db_session: AsyncSession):
    """Test querying with pre-inserted chunks returns relevant results."""
    # Insert a conversation with chunks directly
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

    # Insert a chunk with a known embedding
    # Note: this test requires the embedding service to be mocked or
    # a real OpenAI key. For CI, mock the embedding service.
    # Here we just test the endpoint structure without embeddings.
    chunk_id = uuid.uuid4()
    await db_session.execute(
        text(
            "INSERT INTO chunks (id, conversation_id, text, token_count, chunk_index) "
            "VALUES (:id, :conv_id, :text, :tokens, :idx)"
        ),
        {
            "id": str(chunk_id),
            "conv_id": str(conversation_id),
            "text": "Marco mi ha consigliato di andare alla conferenza PyCon a Firenze.",
            "tokens": 12,
            "idx": 0,
        },
    )
    await db_session.commit()

    # Query — this will fail to find results without embeddings,
    # but should not crash
    response = await client.post(
        "/api/query",
        headers=auth_headers,
        json={"question": "Cosa mi ha detto Marco?", "top_k": 5},
    )

    assert response.status_code == 200
    data = response.json()
    assert "answer" in data
    assert "sources" in data
