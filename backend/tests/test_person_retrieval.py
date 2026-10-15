"""Memory search for a person: "cosa ha detto Marco?" looks in Marco's conversations first."""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Chunk
from app.services.entity_mentions import record_mentions
from app.services.memory_retrieval import people_named_in, retrieve_memory_context
from app.services.people import names_person
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation, make_entity
from tests.mocks import MockEmbeddingService

QUESTION = "Cosa ha detto Marco?"


def test_a_person_is_named_by_first_name_as_a_whole_word():
    assert names_person("Marco Rossi", "cosa ha detto marco?")
    assert names_person("Marco Rossi", "Marco, il preventivo")
    assert not names_person("Marco Rossi", "Ho visto Marcolini")
    assert names_person("Al Bano", "chiama Al Bano") and not names_person("Al Bano", "al mare")


async def _chunk(db: AsyncSession, conversation, text: str) -> None:
    db.add(
        Chunk(
            conversation_id=conversation.id,
            text=text,
            token_count=len(text.split()),
            chunk_index=0,
            embedding=await MockEmbeddingService().embed(text),
        )
    )


@pytest.mark.asyncio
async def test_the_named_person_s_conversations_come_first(db_session: AsyncSession):
    now = datetime.now(timezone.utc)
    with_marco, _ = await make_conversation(
        db_session, started_at=now - timedelta(days=2), title="Preventivo", texts=()
    )
    elsewhere, _ = await make_conversation(
        db_session, started_at=now - timedelta(days=1), title="Altro", texts=()
    )
    marco = make_entity(with_marco, "person", "Marco Rossi", content="Fornitore")
    db_session.add(marco)
    await db_session.flush()
    await record_mentions(db_session, [marco])
    await _chunk(db_session, with_marco, "Il preventivo arriva lunedì, ha detto.")
    # Identical to the question: by similarity alone it would always win
    await _chunk(db_session, elsewhere, QUESTION)
    await db_session.commit()

    assert [p.name for p in await people_named_in(db_session, TEST_USER_ID, QUESTION)] == [
        "Marco Rossi"
    ]
    memory = await retrieve_memory_context(
        db_session,
        TEST_USER_ID,
        QUESTION,
        top_k=1,
        embedding_service=MockEmbeddingService(),
    )

    assert memory.sources[0]["conversation_id"] == with_marco.id
    assert "People asked about:\n- Marco Rossi: Fornitore. Mentioned in:" in memory.context
    assert "Preventivo" in memory.context
    # The best other passage still follows
    assert [s["conversation_id"] for s in memory.sources] == [with_marco.id, elsewhere.id]


@pytest.mark.asyncio
async def test_without_a_known_name_nothing_changes(db_session: AsyncSession):
    now = datetime.now(timezone.utc)
    conversation, _ = await make_conversation(db_session, started_at=now, texts=())
    await _chunk(db_session, conversation, "Cosa ha detto Luca?")
    await db_session.commit()

    memory = await retrieve_memory_context(
        db_session,
        TEST_USER_ID,
        "Cosa ha detto Luca?",
        top_k=1,
        embedding_service=MockEmbeddingService(),
    )

    assert "People asked about" not in memory.context
    assert memory.sources[0]["conversation_id"] == conversation.id
