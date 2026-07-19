"""Background worker for async analysis pipeline.

Processes:
1. STT: picks segments from queue:stt, transcribes, saves transcription
2. Analysis: extracts entities, groups conversations, creates chunks
"""

import asyncio
import logging
import uuid
from pathlib import Path

import redis.asyncio as redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import async_session
from app.models.chunk import Chunk
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.adpcm_decoder import adpcm_to_wav
from app.services.deduplication import deduplicate_entities
from app.services.embedding_openai import get_embedding_service
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_analysis_service
from app.services.stt_openai import get_stt_service
from app.workers.retention import run_retention_loop

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


async def process_stt(redis_client: redis.Redis):
    """Process STT queue: transcribe audio segments."""
    stt_service = get_stt_service()

    while True:
        # Blocking pop from Redis queue
        result = await redis_client.brpop("queue:stt", timeout=5)
        if result is None:
            continue

        _, segment_id_bytes = result
        segment_id = uuid.UUID(segment_id_bytes.decode())
        logger.info(f"Processing STT for segment {segment_id}")

        async with async_session() as db:
            try:
                # Get segment
                segment = await db.get(Segment, segment_id)
                if segment is None:
                    logger.warning(f"Segment {segment_id} not found")
                    continue

                # Update status
                segment.transcription_status = "processing"
                await db.commit()

                # Read audio file
                audio_path = Path(segment.audio_path)
                if not audio_path.exists():
                    logger.error(f"Audio file not found: {audio_path}")
                    segment.transcription_status = "failed"
                    await db.commit()
                    continue

                audio_data = audio_path.read_bytes()

                # Decode ADPCM to WAV for STT
                wav_data = adpcm_to_wav(audio_data)

                # Transcribe
                stt_result = await stt_service.transcribe(wav_data, language=settings.stt_language)

                # Save transcription
                transcription = Transcription(
                    segment_id=segment_id,
                    text=stt_result.text,
                    language=stt_result.language,
                    confidence=stt_result.confidence,
                    stt_provider=settings.stt_provider,
                    stt_model=settings.stt_model,
                )
                db.add(transcription)

                # Update segment status
                segment.transcription_status = "completed"
                await db.commit()

                # Queue for analysis
                await redis_client.lpush("queue:analysis", str(segment_id))
                logger.info(f"STT completed for segment {segment_id}: '{stt_result.text[:50]}...'")

            except Exception as e:
                logger.error(f"STT failed for segment {segment_id}: {e}")
                segment.transcription_status = "failed"
                await db.commit()


async def process_analysis(redis_client: redis.Redis):
    """Process analysis queue: extract entities, group conversations, create embeddings."""
    llm_service = get_llm_analysis_service()
    embedding_service = get_embedding_service()

    while True:
        result = await redis_client.brpop("queue:analysis", timeout=5)
        if result is None:
            continue

        _, segment_id_bytes = result
        segment_id = uuid.UUID(segment_id_bytes.decode())
        logger.info(f"Processing analysis for segment {segment_id}")

        async with async_session() as db:
            try:
                # Get segment with transcription
                segment = await db.get(Segment, segment_id)
                if segment is None or segment.transcription is None:
                    continue

                transcription = segment.transcription
                user_id = segment.user_id

                # --- Conversation grouping ---
                conversation = await assign_to_conversation(db, segment)

                # --- Entity extraction ---
                entities = await extract_entities(
                    llm_service, transcription.text, user_id, transcription.id, conversation.id
                )
                for entity in entities:
                    db.add(entity)

                # Flush to persist entities before dedup
                await db.flush()

                # --- Deduplicate entities ---
                await deduplicate_entities(db, user_id, llm_service)

                # --- Chunking & embedding ---
                # Get all transcriptions in the conversation so far
                conv_segments_query = (
                    select(Transcription.text)
                    .join(Segment, Segment.id == Transcription.segment_id)
                    .where(Segment.conversation_id == conversation.id)
                    .order_by(Segment.recorded_at)
                )
                result = await db.execute(conv_segments_query)
                all_texts = [row[0] for row in result.all()]
                full_text = " ".join(all_texts)

                # Re-chunk the full conversation text
                chunks = chunk_text(
                    full_text, settings.chunk_size_tokens, settings.chunk_overlap_tokens
                )

                # Delete old chunks for this conversation and re-create
                from sqlalchemy import delete
                await db.execute(delete(Chunk).where(Chunk.conversation_id == conversation.id))

                # Create embeddings in batch
                if chunks:
                    embeddings = await embedding_service.embed_batch(chunks)
                    for i, (text, embedding) in enumerate(zip(chunks, embeddings)):
                        chunk = Chunk(
                            conversation_id=conversation.id,
                            text=text,
                            token_count=len(text.split()),  # approximate
                            chunk_index=i,
                            embedding=embedding,
                        )
                        db.add(chunk)

                # --- Generate conversation title & summary ---
                if full_text.strip() and len(full_text.split()) > 10:
                    title, summary = await generate_conversation_summary(
                        llm_service, full_text
                    )
                    conversation.title = title
                    conversation.summary = summary
                    conversation.analysis_status = "completed"

                await db.commit()
                logger.info(
                    f"Analysis completed for segment {segment_id}: "
                    f"{len(entities)} entities, {len(chunks)} chunks"
                )

            except Exception as e:
                logger.error(f"Analysis failed for segment {segment_id}: {e}")
                await db.rollback()


async def assign_to_conversation(db: AsyncSession, segment: Segment) -> Conversation:
    """Assign a segment to an existing or new conversation based on silence timeout."""
    user_id = segment.user_id

    # Find the latest conversation for this user
    query = (
        select(Conversation)
        .where(Conversation.user_id == user_id)
        .order_by(Conversation.started_at.desc())
        .limit(1)
    )
    result = await db.execute(query)
    latest_conversation = result.scalar_one_or_none()

    # If silence before this segment exceeds timeout, create new conversation
    silence_ms = segment.silence_before_ms or 0
    should_create_new = (
        latest_conversation is None or silence_ms >= settings.silence_timeout_ms
    )

    if should_create_new:
        conversation = Conversation(
            user_id=user_id,
            started_at=segment.recorded_at,
            analysis_status="pending",
        )
        db.add(conversation)
        await db.flush()
    else:
        conversation = latest_conversation
        conversation.ended_at = segment.recorded_at

    # Link segment to conversation
    segment.conversation_id = conversation.id
    return conversation


async def extract_entities(
    llm_service,
    text: str,
    user_id: uuid.UUID,
    transcription_id: uuid.UUID,
    conversation_id: uuid.UUID,
) -> list[Entity]:
    """Use LLM to extract structured entities from transcription text."""
    messages = [
        LLMMessage(
            role="system",
            content=(
                "Sei un sistema di estrazione di conoscenza. "
                "Estrai entità strutturate dal testo fornito. "
                "Rispondi in JSON con il seguente formato:\n"
                '{"entities": [{"type": "person|task|idea|event|note", "name": "...", '
                '"content": "...", "metadata": {...}}]}\n\n'
                "Tipi:\n"
                "- person: persone menzionate (metadata: {role, notes})\n"
                "- task: azioni da fare (metadata: {done, due_date, priority})\n"
                "- idea: idee, suggerimenti, concetti (metadata: {tags})\n"
                "- event: eventi, appuntamenti, date (metadata: {event_date, location})\n"
                "- note: qualsiasi altra informazione rilevante (metadata: {tags})\n\n"
                "Se non ci sono entità da estrarre, rispondi con {\"entities\": []}."
            ),
        ),
        LLMMessage(role="user", content=f"Testo:\n\n{text}"),
    ]

    result = await llm_service.complete_json(messages)
    entities_data = result.get("entities", [])

    entities = []
    for e in entities_data:
        entity = Entity(
            user_id=user_id,
            entity_type=e.get("type", "note"),
            name=e.get("name", ""),
            content=e.get("content"),
            metadata_=e.get("metadata", {}),
            source_transcription_id=transcription_id,
            conversation_id=conversation_id,
        )
        entities.append(entity)

    return entities


async def generate_conversation_summary(llm_service, full_text: str) -> tuple[str, str]:
    """Generate a short title and summary for a conversation using LLM.

    Args:
        llm_service: LLM service instance.
        full_text: Full concatenated transcription text of the conversation.

    Returns:
        Tuple of (title, summary).
    """
    # Truncate if too long (save tokens)
    max_chars = 3000
    text_for_summary = full_text[:max_chars] if len(full_text) > max_chars else full_text

    messages = [
        LLMMessage(
            role="system",
            content=(
                "Sei un assistente che organizza conversazioni. "
                "Dato il testo di una conversazione, genera:\n"
                "1. Un titolo breve (max 60 caratteri) che descriva l'argomento principale\n"
                "2. Un riassunto di 2-3 frasi con i punti chiave\n\n"
                "Rispondi in JSON con il formato:\n"
                '{"title": "...", "summary": "..."}\n\n'
                "Rispondi in italiano."
            ),
        ),
        LLMMessage(role="user", content=f"Conversazione:\n\n{text_for_summary}"),
    ]

    result = await llm_service.complete_json(messages)
    title = result.get("title", "Conversazione senza titolo")
    summary = result.get("summary", "")

    return title, summary


def chunk_text(text: str, chunk_size: int, overlap: int) -> list[str]:
    """Split text into chunks of approximately chunk_size tokens with overlap.

    Uses word-based splitting as a simple token approximation.
    """
    words = text.split()
    if not words:
        return []

    chunks = []
    start = 0
    while start < len(words):
        end = start + chunk_size
        chunk = " ".join(words[start:end])
        if chunk.strip():
            chunks.append(chunk)
        start += chunk_size - overlap

    return chunks


async def main():
    """Main entry point for the worker process."""
    logger.info("Starting Echo background worker...")
    redis_client = redis.from_url(settings.redis_url)

    try:
        await asyncio.gather(
            process_stt(redis_client),
            process_analysis(redis_client),
            run_retention_loop(),
        )
    finally:
        await redis_client.aclose()


if __name__ == "__main__":
    asyncio.run(main())
