"""Documents waiting to be read and indexed (services/documents.py), one at a time.

A document is claimed in a short transaction (FOR UPDATE SKIP LOCKED, then claimed_at),
so no lock is held while its text is read (in a thread) or embedded: a delete never waits
on the worker. Its text replaces the file at once; its passages are written only if the
document is still there. One a dead worker claimed is taken again after STALE.
"""

import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, or_, select

from app.core.database import async_session
from app.models.document import Document, DocumentChunk
from app.services.documents import DocumentError, extract_text, passages
from app.services.usage import usage_owner
from app.workers.lifecycle import sleep_or_shutdown

logger = logging.getLogger(__name__)

CHECK_INTERVAL_S = 5
BATCH = 5
EMBED_BATCH = 100
STALE = timedelta(minutes=15)
COULD_NOT_INDEX = "Echo could not index it. Delete it and add it again later."


async def _claim(session_factory) -> uuid.UUID | None:
    now = datetime.now(timezone.utc)
    async with session_factory() as db:
        document = await db.scalar(
            select(Document)
            .where(
                Document.status == "processing",
                or_(Document.claimed_at.is_(None), Document.claimed_at < now - STALE),
            )
            .order_by(Document.created_at)
            .limit(1)
            .with_for_update(skip_locked=True)
        )
        if document is None:
            return None
        document.claimed_at = now
        await db.commit()
        return document.id


async def _fail(session_factory, document_id: uuid.UUID, reason: str) -> None:
    async with session_factory() as db:
        document = await db.get(Document, document_id, with_for_update=True)
        if document is None:
            return
        document.status = "failed"
        document.error = reason
        document.raw = None
        await db.commit()


async def _index_one(session_factory, embeddings, document_id: uuid.UUID) -> None:
    async with session_factory() as db:
        row = (
            await db.execute(
                select(Document.user_id, Document.kind, Document.raw, Document.text).where(
                    Document.id == document_id
                )
            )
        ).first()
    if row is None:
        return
    usage_owner.set(row.user_id)
    text = row.text
    if row.raw is not None:
        try:
            # Parsing is CPU work: never on the event loop
            text, pages = await asyncio.to_thread(extract_text, row.kind, row.raw)
        except DocumentError as exc:
            await _fail(session_factory, document_id, str(exc))
            return
        async with session_factory() as db:
            document = await db.get(Document, document_id, with_for_update=True)
            if document is None:
                return
            # The text replaces the file at once
            document.text, document.pages = text, pages
            document.word_count = len(text.split())
            document.raw = None
            await db.commit()

    parts = passages(text)
    try:
        vectors: list[list[float]] = []
        for start in range(0, len(parts), EMBED_BATCH):
            vectors += await embeddings.embed_batch(parts[start : start + EMBED_BATCH])
    except Exception:
        logger.warning("[Documents] Could not embed %s", document_id, exc_info=True)
        await _fail(session_factory, document_id, COULD_NOT_INDEX)
        return

    async with session_factory() as db:
        document = await db.get(Document, document_id, with_for_update=True)
        if document is None or document.status != "processing":
            # Deleted while it was being read: nothing to keep
            return
        await db.execute(delete(DocumentChunk).where(DocumentChunk.document_id == document_id))
        for index, (passage, vector) in enumerate(zip(parts, vectors)):
            db.add(
                DocumentChunk(
                    document_id=document_id,
                    user_id=document.user_id,
                    chunk_index=index,
                    text=passage,
                    embedding=vector,
                )
            )
        document.status = "ready"
        document.error = None
        document.claimed_at = None
        await db.commit()


async def index_waiting_documents(*, session_factory=async_session, embeddings=None) -> int:
    """Read and index up to BATCH waiting documents, one by one; returns how many."""
    if embeddings is None:
        from app.services.embedding_openai import get_embedding_service

        embeddings = get_embedding_service()
    handled = 0
    while handled < BATCH:
        document_id = await _claim(session_factory)
        if document_id is None:
            break
        await _index_one(session_factory, embeddings, document_id)
        handled += 1
    return handled


async def run_documents_loop(shutdown_event: asyncio.Event | None = None):
    logger.info("[Documents] Loop started")
    while not (shutdown_event and shutdown_event.is_set()):
        try:
            handled = await index_waiting_documents()
            if handled:
                logger.info("[Documents] Indexed %s", handled)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Documents] Indexing failed")
        if await sleep_or_shutdown(CHECK_INTERVAL_S, shutdown_event):
            return
