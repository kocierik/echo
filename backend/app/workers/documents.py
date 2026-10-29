"""Documents waiting to be indexed: split into chunks, embedded and stored, so the memory
can search them (services/documents.py). One that cannot be embedded is left failed, with
the reason the app shows."""

import asyncio
import logging

from sqlalchemy import delete, select

from app.core.database import async_session
from app.models.document import Document, DocumentChunk
from app.services.chunking import chunk_text
from app.services.usage import usage_owner
from app.workers.lifecycle import sleep_or_shutdown

logger = logging.getLogger(__name__)

CHECK_INTERVAL_S = 5
BATCH = 5
# Passages a little shorter than a conversation's: a document's are denser
CHUNK_WORDS = 300
OVERLAP_WORDS = 40
EMBED_BATCH = 100


async def index_waiting_documents(*, session_factory=async_session, embeddings=None) -> int:
    """Index the documents waiting; returns how many were handled."""
    if embeddings is None:
        from app.services.embedding_openai import get_embedding_service

        embeddings = get_embedding_service()
    handled = 0
    async with session_factory() as db:
        waiting = list(await db.scalars(
            select(Document)
            .where(Document.status == "processing")
            .order_by(Document.created_at)
            .limit(BATCH)
            .with_for_update(skip_locked=True)
        ))
        for document in waiting:
            usage_owner.set(document.user_id)
            passages = chunk_text(document.text, CHUNK_WORDS, OVERLAP_WORDS) or [document.text]
            try:
                vectors: list[list[float]] = []
                for start in range(0, len(passages), EMBED_BATCH):
                    vectors += await embeddings.embed_batch(passages[start : start + EMBED_BATCH])
            except Exception:
                logger.warning("[Documents] Could not embed %s", document.id, exc_info=True)
                document.status = "failed"
                document.error = "Echo could not index it. Delete it and add it again later."
                handled += 1
                continue
            await db.execute(delete(DocumentChunk).where(DocumentChunk.document_id == document.id))
            for index, (text, vector) in enumerate(zip(passages, vectors)):
                db.add(DocumentChunk(
                    document_id=document.id, user_id=document.user_id, chunk_index=index,
                    text=text, embedding=vector,
                ))
            document.status = "ready"
            document.error = None
            handled += 1
        await db.commit()
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
