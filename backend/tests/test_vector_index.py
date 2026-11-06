"""The vector indexes find what a full read finds: the baseline's IVFFlat indexes, made on
empty tables, missed rows once Postgres used them (memory answers lost conversations, the
CI failed now and then). Migration 035 makes them HNSW."""

import uuid
from datetime import datetime, timezone

from sqlalchemy import text

from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService


def _vector(values: list[float]) -> str:
    return "[" + ",".join(map(str, values)) + "]"


async def test_a_memory_search_through_the_index_finds_the_conversation(db_session):
    embeddings = MockEmbeddingService()
    conversation = uuid.uuid4()
    await db_session.execute(
        text(
            "INSERT INTO conversations (id, user_id, started_at, analysis_status) "
            "VALUES (:id, :user, :at, 'completed')"
        ),
        {"id": str(conversation), "user": str(TEST_USER_ID), "at": datetime.now(timezone.utc)},
    )
    await db_session.execute(
        text(
            "INSERT INTO chunks (id, conversation_id, text, token_count, chunk_index, embedding) "
            "VALUES (:id, :conversation, 'x', 1, 0, CAST(:vector AS vector))"
        ),
        {
            "id": str(uuid.uuid4()),
            "conversation": str(conversation),
            "vector": _vector(await embeddings.embed("Marco racconta del viaggio in Giappone")),
        },
    )
    await db_session.commit()

    # The index, as Postgres picks it for a large table
    await db_session.execute(text("SET LOCAL enable_seqscan = off"))
    found = await db_session.scalar(
        text(
            "SELECT count(*) FROM (SELECT id FROM chunks WHERE conversation_id = :conversation "
            "ORDER BY embedding <=> CAST(:question AS vector) LIMIT 5) found"
        ),
        {
            "conversation": str(conversation),
            "question": _vector(await embeddings.embed("Di cosa abbiamo parlato a cena?")),
        },
    )

    assert found == 1
