"""Background worker for async analysis pipeline.

Processes:
1. STT: picks segments from queue:stt, transcribes, saves transcription
2. Analysis: extracts entities, groups conversations, creates chunks

Features:
- Exponential backoff retry on transient failures
- Graceful shutdown on SIGTERM/SIGINT (waits up to 30s for in-progress tasks)
- Dead letter queue for segments that fail after all retries
"""

import asyncio
import json
import logging
import signal
import uuid
from datetime import datetime, timezone
from pathlib import Path

import redis.asyncio as redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import async_session
from app.core.logging import setup_logging
from app.models.chunk import Chunk
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.adpcm_decoder import adpcm_to_wav
from app.services.chunking import chunk_text
from app.services.deduplication import deduplicate_entities
from app.services.embedding_openai import get_embedding_service
from app.services.entity_consolidation import consolidate_entities
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_analysis_service
from app.services.stt_openai import get_stt_service
from app.services.transcription_enhancer import (
    build_stt_prompt,
    clean_transcription,
    is_meaningful_transcription,
)
from app.workers.digest import run_digest_loop
from app.workers.retention import run_retention_loop
from app.workers.retry import RetryExhaustedError, retry_with_backoff

# Configure structured logging
setup_logging()
logger = logging.getLogger(__name__)

# Shutdown coordination
SHUTDOWN_TIMEOUT_S = 30
shutdown_event = asyncio.Event()


def _handle_signal(sig: signal.Signals):
    """Signal handler: set shutdown event."""
    logger.info(f"[Shutdown] Received {sig.name}, initiating graceful shutdown...")
    shutdown_event.set()


async def push_to_dead_letter(
    redis_client: redis.Redis,
    segment_id: uuid.UUID,
    step: str,
    error: str,
    attempts: int = 3,
):
    """Push a failed segment to the dead letter queue."""
    entry = {
        "segment_id": str(segment_id),
        "step": step,
        "error": str(error)[:500],
        "attempts": attempts,
        "failed_at": datetime.now(timezone.utc).isoformat(),
    }
    await redis_client.lpush("queue:dead-letter", json.dumps(entry))
    logger.warning(f"[DeadLetter] Segment {segment_id} pushed to dead letter (step={step})")


async def process_stt(redis_client: redis.Redis):
    """Process STT queue: transcribe audio segments with context-aware prompting."""
    stt_service = get_stt_service()

    while not shutdown_event.is_set():
        # Blocking pop from Redis queue (short timeout to check shutdown flag)
        result = await redis_client.brpop("queue:stt", timeout=2)
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
                    await push_to_dead_letter(
                        redis_client, segment_id, "stt", "Audio file not found"
                    )
                    continue

                audio_data = audio_path.read_bytes()

                # Decode ADPCM to WAV for STT
                wav_data = adpcm_to_wav(audio_data)

                # Build context-aware prompt from known entities
                stt_prompt = await build_stt_prompt(db, segment.user_id)

                # Transcribe with retry (passing context prompt for better accuracy)
                stt_result = await retry_with_backoff(
                    stt_service.transcribe,
                    wav_data,
                    language=settings.stt_language,
                    prompt=stt_prompt or None,
                    operation_name=f"STT segment {segment_id}",
                )

                # Post-process: clean artifacts and normalize
                cleaned_text = clean_transcription(stt_result.text)

                # Save transcription
                transcription = Transcription(
                    segment_id=segment_id,
                    text=cleaned_text,
                    language=stt_result.language,
                    confidence=stt_result.confidence,
                    stt_provider=settings.stt_provider,
                    stt_model=settings.stt_model,
                )
                db.add(transcription)

                # Update segment status
                segment.transcription_status = "completed"
                await db.commit()

                # Only queue for analysis if transcription is meaningful
                if is_meaningful_transcription(cleaned_text):
                    await redis_client.lpush("queue:analysis", str(segment_id))
                    logger.info(
                        f"STT completed for segment {segment_id}: '{cleaned_text[:80]}...'"
                    )
                else:
                    logger.info(
                        f"STT completed but skipping analysis (trivial): "
                        f"segment {segment_id} text='{cleaned_text}'"
                    )

            except RetryExhaustedError as e:
                logger.error(f"STT failed permanently for segment {segment_id}: {e}")
                segment.transcription_status = "failed"
                await db.commit()
                await push_to_dead_letter(
                    redis_client, segment_id, "stt", str(e.last_error), e.attempts
                )

            except asyncio.CancelledError:
                # Shutdown in progress — requeue the segment
                logger.info(f"[Shutdown] STT interrupted for segment {segment_id}, requeueing")
                await redis_client.lpush("queue:stt", str(segment_id))
                raise

            except Exception as e:
                logger.error(f"STT unexpected error for segment {segment_id}: {e}")
                segment.transcription_status = "failed"
                await db.commit()
                await push_to_dead_letter(redis_client, segment_id, "stt", str(e))


async def process_analysis(redis_client: redis.Redis):
    """Process analysis queue: extract entities, group conversations, create embeddings."""
    llm_service = get_llm_analysis_service()
    embedding_service = get_embedding_service()

    while not shutdown_event.is_set():
        result = await redis_client.brpop("queue:analysis", timeout=2)
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

                # --- Fetch known people for context-aware extraction ---
                known_people_query = (
                    select(Entity.name)
                    .where(Entity.user_id == user_id)
                    .where(Entity.entity_type == "person")
                    .order_by(Entity.updated_at.desc())
                    .limit(20)
                )
                people_result = await db.execute(known_people_query)
                known_people = [row[0] for row in people_result.all()]

                # --- Entity extraction (with retry + known people context) ---
                entities = await retry_with_backoff(
                    extract_entities,
                    llm_service,
                    transcription.text,
                    user_id,
                    transcription.id,
                    conversation.id,
                    known_people=known_people,
                    operation_name=f"Entity extraction segment {segment_id}",
                )

                # --- Consolidate with existing entities ---
                # Update existing entities if new info refers to something already known,
                # only insert truly new entities
                new_entities = await consolidate_entities(db, entities, user_id)
                for entity in new_entities:
                    db.add(entity)

                # Generate embeddings for NEW entities only (existing ones already have them)
                if new_entities:
                    entity_texts = [
                        f"{e.name}: {e.content}" if e.content else e.name
                        for e in new_entities
                    ]
                    entity_embeddings = await retry_with_backoff(
                        embedding_service.embed_batch,
                        entity_texts,
                        operation_name=f"Entity embeddings segment {segment_id}",
                    )
                    for entity, emb in zip(new_entities, entity_embeddings):
                        entity.embedding = emb

                # Flush to persist entities before dedup
                await db.flush()

                # --- Deduplicate entities (catches remaining fuzzy duplicates) ---
                await deduplicate_entities(db, user_id, llm_service)

                # --- Incremental chunking & embedding ---
                # Only embed the NEW segment's text as an additional chunk,
                # instead of re-chunking the entire conversation every time.
                # Full re-chunking happens only when conversation is "completed".
                new_text = transcription.text.strip()
                if new_text and len(new_text.split()) > 5:
                    # Get current max chunk_index for this conversation
                    max_idx_query = (
                        select(Chunk.chunk_index)
                        .where(Chunk.conversation_id == conversation.id)
                        .order_by(Chunk.chunk_index.desc())
                        .limit(1)
                    )
                    max_idx_result = await db.execute(max_idx_query)
                    max_idx_row = max_idx_result.first()
                    next_index = (max_idx_row[0] + 1) if max_idx_row else 0

                    # Chunk only the new text
                    new_chunks = chunk_text(
                        new_text, settings.chunk_size_tokens, settings.chunk_overlap_tokens
                    )

                    if new_chunks:
                        new_embeddings = await retry_with_backoff(
                            embedding_service.embed_batch,
                            new_chunks,
                            operation_name=f"Incremental embeddings segment {segment_id}",
                        )
                        for i, (text, embedding) in enumerate(zip(new_chunks, new_embeddings)):
                            chunk = Chunk(
                                conversation_id=conversation.id,
                                text=text,
                                token_count=len(text.split()),
                                chunk_index=next_index + i,
                                embedding=embedding,
                            )
                            db.add(chunk)

                # --- Generate conversation title & summary (with retry) ---
                # Get full conversation text for summary
                conv_segments_query = (
                    select(Transcription.text)
                    .join(Segment, Segment.id == Transcription.segment_id)
                    .where(Segment.conversation_id == conversation.id)
                    .order_by(Segment.recorded_at)
                )
                result = await db.execute(conv_segments_query)
                all_texts = [row[0] for row in result.all()]
                full_text = " ".join(all_texts)

                if full_text.strip() and len(full_text.split()) > 10:
                    title, summary = await retry_with_backoff(
                        generate_conversation_summary,
                        llm_service,
                        full_text,
                        operation_name=f"Summary segment {segment_id}",
                    )
                    conversation.title = title
                    conversation.summary = summary
                    conversation.analysis_status = "completed"

                await db.commit()
                logger.info(
                    f"Analysis completed for segment {segment_id}: "
                    f"{len(entities)} entities, "
                    f"{len(new_chunks) if new_text and len(new_text.split()) > 5 else 0} chunks"
                )

            except RetryExhaustedError as e:
                logger.error(f"Analysis failed permanently for segment {segment_id}: {e}")
                await db.rollback()
                await push_to_dead_letter(
                    redis_client, segment_id, "analysis", str(e.last_error), e.attempts
                )

            except asyncio.CancelledError:
                logger.info(
                    f"[Shutdown] Analysis interrupted for segment {segment_id}, requeueing"
                )
                await db.rollback()
                await redis_client.lpush("queue:analysis", str(segment_id))
                raise

            except Exception as e:
                logger.error(f"Analysis unexpected error for segment {segment_id}: {e}")
                await db.rollback()
                await push_to_dead_letter(redis_client, segment_id, "analysis", str(e))


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
    known_people: list[str] | None = None,
) -> list[Entity]:
    """Use LLM to extract structured entities from transcription text.

    Args:
        llm_service: LLM service for extraction.
        text: Transcription text to analyze.
        user_id: Owner user ID.
        transcription_id: Source transcription.
        conversation_id: Parent conversation.
        known_people: Optional list of known person names to help LLM
                      recognize and normalize references.
    """
    # Build system prompt with known people context
    people_context = ""
    if known_people:
        names_list = ", ".join(known_people[:15])
        people_context = (
            f"\n\nPersone già note all'utente: {names_list}. "
            "Se riconosci riferimenti a queste persone (anche con varianti del nome, "
            "soprannomi, o pronomi), usa il nome canonico dalla lista."
        )

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
                "Regole importanti:\n"
                "- Estrai SOLO informazioni esplicitamente presenti nel testo\n"
                "- Per i task, formula il nome come azione (verbo all'infinito)\n"
                "- Per le persone, usa il nome completo se disponibile\n"
                "- Ignora filler e parole senza contenuto informativo\n"
                "- Se non ci sono entità da estrarre, rispondi con {\"entities\": []}."
                f"{people_context}"
            ),
        ),
        LLMMessage(role="user", content=f"Testo:\n\n{text}"),
    ]

    result = await llm_service.complete_json(messages)
    entities_data = result.get("entities", [])

    entities = []
    for e in entities_data:
        # Skip entities with empty names
        name = e.get("name", "").strip()
        if not name:
            continue

        entity = Entity(
            user_id=user_id,
            entity_type=e.get("type", "note"),
            name=name,
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


async def main():
    """Main entry point for the worker process."""
    logger.info("Starting Echo background worker...")

    # Register signal handlers
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _handle_signal, sig)

    redis_client = redis.from_url(settings.redis_url)

    # Create worker tasks
    tasks = [
        asyncio.create_task(process_stt(redis_client), name="stt_worker"),
        asyncio.create_task(process_analysis(redis_client), name="analysis_worker"),
        asyncio.create_task(run_retention_loop(), name="retention_worker"),
        asyncio.create_task(run_digest_loop(shutdown_event), name="digest_worker"),
    ]

    # Wait for shutdown signal
    await shutdown_event.wait()
    logger.info(f"[Shutdown] Waiting up to {SHUTDOWN_TIMEOUT_S}s for tasks to finish...")

    # Cancel all tasks and wait with timeout
    for task in tasks:
        task.cancel()

    results = await asyncio.gather(*tasks, return_exceptions=True)

    for task, result in zip(tasks, results):
        if isinstance(result, Exception) and not isinstance(result, asyncio.CancelledError):
            logger.error(f"[Shutdown] Task {task.get_name()} ended with error: {result}")

    await redis_client.aclose()
    logger.info("[Shutdown] Worker stopped cleanly.")


if __name__ == "__main__":
    asyncio.run(main())
