"""Transactional rebuilding of conversation-derived memory."""

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
    extract_entities,
    generate_conversation_summary,
)
from app.services.chunking import chunk_text
from app.services.embedding_base import EmbeddingService
from app.services.llm_base import LLMService
from app.workers.retry import retry_with_backoff


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
        recorded_dates = {
            transcription_id: to_user_local_date(recorded_at)
            for transcription_id, _, recorded_at in rows
        }

        await db.execute(delete(Chunk).where(Chunk.conversation_id == conversation_id))
        await db.execute(delete(Entity).where(Entity.conversation_id == conversation_id))
        await db.flush()

        conversation.title = None
        conversation.summary = None

        if not transcriptions:
            conversation.analysis_status = "completed"
            await db.commit()
            return ConversationReanalysisResult(found=True)

        people_result = await db.execute(
            select(Entity.name)
            .where(Entity.user_id == conversation.user_id)
            .where(Entity.entity_type == "person")
            .order_by(Entity.updated_at.desc())
            .limit(20)
        )
        known_people = [row[0] for row in people_result.all()]

        fresh_entities: list[Entity] = []
        for transcription_id, text in transcriptions:
            extracted = await retry_with_backoff(
                extract_entities,
                llm_service,
                text,
                conversation.user_id,
                transcription_id,
                conversation.id,
                known_people=known_people,
                reference_date=recorded_dates[transcription_id],
                operation_name=(
                    f"Reanalysis entity extraction conversation {conversation_id}"
                ),
            )
            fresh_entities.extend(extracted)

        for entity in fresh_entities:
            db.add(entity)

        if fresh_entities:
            entity_texts = [
                f"{entity.name}: {entity.content}" if entity.content else entity.name
                for entity in fresh_entities
            ]
            entity_embeddings = await retry_with_backoff(
                embedding_service.embed_batch,
                entity_texts,
                operation_name=f"Reanalysis entity embeddings {conversation_id}",
            )
            for entity, embedding in zip(fresh_entities, entity_embeddings):
                entity.embedding = embedding

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

        if len(full_text.split()) > 10:
            title, summary = await retry_with_backoff(
                generate_conversation_summary,
                llm_service,
                full_text,
                operation_name=f"Reanalysis summary {conversation_id}",
            )
            conversation.title = title
            conversation.summary = summary

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
