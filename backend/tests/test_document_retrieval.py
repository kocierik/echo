"""Memory answers search the user's documents too, naming the document, and only what is
close enough: an unrelated document never crowds an answer."""

import uuid

from app.models.document import Document, DocumentChunk
from app.services.memory_retrieval import retrieve_memory_context
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService

QUESTION = "quanto pago di affitto"


async def _document(db, title, passage, *, matches, user_id=TEST_USER_ID):
    mock = MockEmbeddingService()
    # The same text as the question embeds the same: the closest possible passage
    vector = await mock.embed(QUESTION if matches else f"unrelated {title}")
    document = Document(
        id=uuid.uuid4(),
        user_id=user_id,
        title=title,
        kind="docx",
        size_bytes=10,
        status="ready",
        text=passage,
        word_count=len(passage.split()),
    )
    db.add(document)
    await db.flush()
    db.add(
        DocumentChunk(
            document_id=document.id,
            user_id=user_id,
            chunk_index=0,
            text=passage,
            embedding=vector,
        )
    )
    await db.commit()
    return document


async def _ask(db):
    return await retrieve_memory_context(
        db, TEST_USER_ID, QUESTION, embedding_service=MockEmbeddingService()
    )


async def test_a_document_passage_answers_naming_its_document(db_session):
    await _document(
        db_session, "Contratto affitto.docx", "Il canone è di 900 euro al mese.", matches=True
    )

    memory = await _ask(db_session)

    assert 'From your document "Contratto affitto.docx"' in memory.context
    assert "900 euro" in memory.context


async def test_an_unrelated_document_stays_out(db_session):
    await _document(db_session, "Ricette.md", "Pasta al pomodoro.", matches=False)

    memory = await _ask(db_session)

    assert "Ricette.md" not in memory.context


async def test_someone_elses_document_stays_out(db_session):
    await _document(db_session, "Loro.docx", "Il loro canone.", matches=True, user_id=uuid.uuid4())

    assert "Loro.docx" not in (await _ask(db_session)).context


async def test_a_deleted_document_is_never_found_again(db_session):
    document = await _document(db_session, "Vecchio.docx", "Canone vecchio.", matches=True)
    await db_session.delete(document)
    await db_session.commit()

    assert "Vecchio.docx" not in (await _ask(db_session)).context
