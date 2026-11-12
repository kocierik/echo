"""Transactional rebuilding of conversation-derived memory."""

import logging
import uuid
from dataclasses import dataclass

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.timezone import to_user_local_date
from app.models.chunk import Chunk
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.analysis_pipeline import (
    CONVERSATION_WINDOW_LINES,
    assistant_names,
    extract_entities,
    known_people_names,
    save_entities,
)
from app.services.chunking import chunk_text
from app.services.conversation_close import write_summary
from app.services.embedding_base import EmbeddingService
from app.services.entity_mentions import record_mentions, release_conversation
from app.services.llm_base import LLMService
from app.services.usage import usage_owner
from app.workers.retry import RetryExhaustedError, retry_with_backoff

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ConversationReanalysisResult:
    found: bool
    transcription_count: int = 0
    entity_count: int = 0
    chunk_count: int = 0


async def reanalyse_conversation(
    db: AsyncSession,
    conversation_id: uuid.UUID,
    llm_service: LLMService,
    embedding_service: EmbeddingService,
) -> ConversationReanalysisResult:
    """Rebuild one conversation's derived rows from its current transcriptions."""
    try:
        conversation_result = await db.execute(
            select(Conversation)
            .where(Conversation.id == conversation_id)
            .with_for_update()
        )
        conversation = conversation_result.scalar_one_or_none()
        if conversation is None:
            return ConversationReanalysisResult(found=False)
        usage_owner.set(conversation.user_id)

        transcription_result = await db.execute(
            select(Transcription.id, Transcription.text, Segment.recorded_at)
            .join(Segment, Segment.id == Transcription.segment_id)
            .where(Segment.conversation_id == conversation_id)
            .order_by(Segment.recorded_at)
        )
        rows = [
            (transcription_id, text.strip(), recorded_at)
            for transcription_id, text, recorded_at in transcription_result.all()
            if text.strip()
        ]
        transcriptions = [(transcription_id, text) for transcription_id, text, _ in rows]

        # Photo descriptions are not rebuilt from transcripts: they stay
        await db.execute(
            delete(Chunk)
            .where(Chunk.conversation_id == conversation_id)
            .where(Chunk.photo_id.is_(None))
        )
        # Entities also mentioned in other conversations survive (moved there). What a
        # photo showed is not in the transcripts: those entities stay as they are
        await release_conversation(db, conversation_id)
        from_photos = Entity.metadata_["photo_id"].astext.isnot(None)
        # People are the user's own (People), with their facts and their voice: a
        # conversation analysed again never deletes them, only its mention of them
        await db.execute(
            delete(Entity)
            .where(Entity.conversation_id == conversation_id)
            .where(~from_photos)
            .where(Entity.entity_type != "person")
        )
        await db.flush()
        photo_entities = (
            await db.execute(
                select(Entity).where(Entity.conversation_id == conversation_id, from_photos)
            )
        ).scalars().all()
        await record_mentions(db, list(photo_entities))

        conversation.title = None
        conversation.summary = None
        conversation.emoji = None

        if not transcriptions:
            conversation.analysis_status = "completed"
            await db.commit()
            return ConversationReanalysisResult(found=True)

        known_people = await known_people_names(db, conversation.user_id)
        assistants = await assistant_names(db, conversation.user_id)

        # Read whole, once (in parts when very long): a line alone gave a note a line
        fresh_entities: list[Entity] = []
        for first in range(0, len(rows), CONVERSATION_WINDOW_LINES):
            window = rows[first:first + CONVERSATION_WINDOW_LINES]
            extracted = await retry_with_backoff(
                extract_entities,
                llm_service,
                "\n".join(f"[{n}] {text}" for n, (_, text, _) in enumerate(window, start=1)),
                conversation.user_id,
                None,
                conversation.id,
                known_people=known_people,
                reference_date=to_user_local_date(window[0][2]),
                not_people=assistants,
                line_ids=[transcription_id for transcription_id, _, _ in window],
                operation_name=(
                    f"Reanalysis entity extraction conversation {conversation_id}"
                ),
            )
            fresh_entities.extend(extracted)

        # Merged into what is already known from other conversations, embedded, mentioned
        await save_entities(
            db,
            fresh_entities,
            conversation.user_id,
            llm_service,
            embedding_service,
            label=f"conversation {conversation_id}",
        )

        full_text = " ".join(text for _, text in transcriptions)
        chunks = chunk_text(
            full_text,
            settings.chunk_size_tokens,
            settings.chunk_overlap_tokens,
        )
        if chunks:
            chunk_embeddings = await retry_with_backoff(
                embedding_service.embed_batch,
                chunks,
                operation_name=f"Reanalysis chunk embeddings {conversation_id}",
            )
            for index, (text, embedding) in enumerate(zip(chunks, chunk_embeddings)):
                db.add(
                    Chunk(
                        conversation_id=conversation.id,
                        text=text,
                        token_count=len(text.split()),
                        chunk_index=index,
                        embedding=embedding,
                    )
                )

        if len(full_text.split()) > settings.summary_min_words:
            try:
                # Summary, topics, and the facts: as for any closed conversation
                await write_summary(db, llm_service, conversation, full_text)
            except RetryExhaustedError:
                # Left without one: the summaries loop tries again (workers/summaries.py)
                logger.warning("[Reanalysis] No summary yet for %s", conversation_id)

        conversation.analysis_status = "completed"
        await db.commit()
        return ConversationReanalysisResult(
            found=True,
            transcription_count=len(transcriptions),
            entity_count=len(fresh_entities),
            chunk_count=len(chunks),
        )
    except Exception:
        await db.rollback()
        raise
