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
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import redis.asyncio as redis
from sqlalchemy import select

from app.actions.voice import find_wake
from app.core.config import settings
from app.core.database import async_session
from app.core.logging import setup_logging
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.adpcm_decoder import adpcm_to_wav
from app.services.analysis_pipeline import (
    AnalysisPipeline,
)
from app.services.conversation_reanalysis import reanalyse_conversation
from app.services.embedding_openai import get_embedding_service
from app.services.llm_openai import get_llm_analysis_service
from app.services.speaker_detector import classify_segment
from app.services.stt_openai import get_stt_service
from app.services.transcription_enhancer import (
    build_stt_context,
    clean_transcription,
    is_meaningful_transcription,
    speaker_prefix,
)
from app.workers.digest import run_digest_loop
from app.workers.lifecycle import SHUTDOWN_TIMEOUT_S, stop_tasks
from app.workers.retention import run_retention_loop
from app.workers.retry import RetryExhaustedError, retry_with_backoff
from app.workers.summaries import run_summary_loop
from app.workers.voice_requests import VOICE_QUEUE, process_voice_queue

# Configure structured logging
setup_logging()
logger = logging.getLogger(__name__)

# Shutdown coordination
shutdown_event = asyncio.Event()

REANALYSIS_LOCK_TTL_S = 300
REANALYSIS_LOCK_RENEWAL_S = 120
REANALYSIS_LOCK_BACKOFF_S = (2, 5, 10, 30)
MAX_REANALYSES_PER_LOCK = 3

_RENEW_LOCK_SCRIPT = """
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('expire', KEYS[1], ARGV[2])
end
return 0
"""

_RELEASE_LOCK_SCRIPT = """
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
end
return 0
"""

_DELETE_LATEST_IF_UNCHANGED_SCRIPT = """
-- Delete only the exact latest marker observed by this worker.
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
end
return 0
"""


@dataclass(frozen=True)
class ReanalysisPayload:
    conversation_id: uuid.UUID
    requested_at: datetime
    attempts: int = 0

    def to_json(self) -> str:
        return json.dumps(
            {
                "conversation_id": str(self.conversation_id),
                "requested_at": self.requested_at.isoformat(),
                "attempts": self.attempts,
            }
        )


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


async def push_reanalysis_to_dead_letter(
    redis_client: redis.Redis,
    raw_payload: str,
    error: str,
    *,
    attempts: int = 0,
    conversation_id: uuid.UUID | None = None,
):
    entry = {
        "conversation_id": str(conversation_id) if conversation_id else None,
        "step": "reanalysis",
        "error": str(error)[:500],
        "attempts": attempts,
        "payload": raw_payload[:1000],
        "failed_at": datetime.now(timezone.utc).isoformat(),
    }
    await redis_client.lpush("queue:dead-letter", json.dumps(entry))
    logger.warning(
        "[DeadLetter] Reanalysis payload pushed to dead letter "
        f"(conversation_id={conversation_id})"
    )


def _parse_aware_datetime(value: object) -> datetime:
    if not isinstance(value, str):
        raise ValueError("requested_at must be an ISO timestamp string")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("requested_at must include a timezone offset")
    return parsed


def _parse_reanalysis_payload(raw_payload: str | bytes) -> ReanalysisPayload:
    decoded = raw_payload.decode() if isinstance(raw_payload, bytes) else raw_payload
    data = json.loads(decoded)
    if not isinstance(data, dict):
        raise ValueError("reanalysis payload must be a JSON object")

    conversation_id = uuid.UUID(str(data.get("conversation_id", "")))
    requested_at = _parse_aware_datetime(data.get("requested_at"))
    attempts = data.get("attempts", 0)
    if isinstance(attempts, bool) or not isinstance(attempts, int) or attempts < 0:
        raise ValueError("attempts must be a non-negative integer")
    return ReanalysisPayload(conversation_id, requested_at, attempts)


def _decode_redis_token(value: object) -> str | None:
    if isinstance(value, bytes):
        try:
            return value.decode()
        except UnicodeDecodeError:
            return None
    return value if isinstance(value, str) else None


async def _renew_reanalysis_lock(
    redis_client: redis.Redis,
    lock_key: str,
    lock_token: str,
    lock_lost: asyncio.Event,
):
    try:
        while True:
            await asyncio.sleep(REANALYSIS_LOCK_RENEWAL_S)
            renewed = await redis_client.eval(
                _RENEW_LOCK_SCRIPT,
                1,
                lock_key,
                lock_token,
                REANALYSIS_LOCK_TTL_S,
            )
            if not renewed:
                lock_lost.set()
                logger.warning(f"[Reanalysis] Lost distributed lock {lock_key}")
                return
    except asyncio.CancelledError:
        raise
    except Exception:
        lock_lost.set()
        logger.exception(f"[Reanalysis] Failed to renew distributed lock {lock_key}")


async def _owns_reanalysis_lock(
    redis_client: redis.Redis,
    lock_key: str,
    lock_token: str,
    lock_lost: asyncio.Event,
) -> bool:
    if lock_lost.is_set():
        return False
    try:
        observed_token = await redis_client.get(lock_key)
    except asyncio.CancelledError:
        raise
    except Exception:
        lock_lost.set()
        logger.exception(f"[Reanalysis] Failed to verify distributed lock {lock_key}")
        return False

    owns_lock = _decode_redis_token(observed_token) == lock_token
    if not owns_lock:
        lock_lost.set()
    return owns_lock


async def _requeue_after_reanalysis_lock_loss(
    redis_client: redis.Redis,
    payload: ReanalysisPayload,
    requested_at: datetime,
) -> None:
    max_retry_attempt = max(0, len(REANALYSIS_LOCK_BACKOFF_S) - 1)
    retry_payload = ReanalysisPayload(
        payload.conversation_id,
        requested_at,
        min(payload.attempts + 1, max_retry_attempt),
    )
    await redis_client.lpush("queue:reanalysis", retry_payload.to_json())
    logger.warning(
        f"[Reanalysis] Requeued conversation {payload.conversation_id} after lock loss"
    )


async def _process_reanalysis_payload(
    redis_client: redis.Redis,
    raw_payload: str | bytes,
    llm_service,
    embedding_service,
):
    decoded_payload = (
        raw_payload.decode(errors="replace")
        if isinstance(raw_payload, bytes)
        else raw_payload
    )
    try:
        payload = _parse_reanalysis_payload(raw_payload)
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        await push_reanalysis_to_dead_letter(redis_client, decoded_payload, str(exc))
        return

    current_payload = payload.to_json()
    lock_key = f"reanalysis:lock:{payload.conversation_id}"
    lock_token = uuid.uuid4().hex
    lock_acquired = False
    lock_lost = asyncio.Event()
    renewal_task: asyncio.Task | None = None

    try:
        lock_acquired = bool(
            await redis_client.set(
                lock_key,
                lock_token,
                nx=True,
                ex=REANALYSIS_LOCK_TTL_S,
            )
        )
        if not lock_acquired:
            if payload.attempts >= len(REANALYSIS_LOCK_BACKOFF_S):
                await push_reanalysis_to_dead_letter(
                    redis_client,
                    current_payload,
                    "distributed lock unavailable",
                    attempts=payload.attempts,
                    conversation_id=payload.conversation_id,
                )
                return

            await asyncio.sleep(REANALYSIS_LOCK_BACKOFF_S[payload.attempts])
            retry_payload = ReanalysisPayload(
                payload.conversation_id,
                payload.requested_at,
                payload.attempts + 1,
            )
            await redis_client.lpush("queue:reanalysis", retry_payload.to_json())
            return

        renewal_task = asyncio.create_task(
            _renew_reanalysis_lock(
                redis_client,
                lock_key,
                lock_token,
                lock_lost,
            ),
            name=f"reanalysis_lock_{payload.conversation_id}",
        )
        processed_at = payload.requested_at
        latest_key = f"reanalysis:latest:{payload.conversation_id}"

        for run_index in range(MAX_REANALYSES_PER_LOCK):
            if not await _owns_reanalysis_lock(
                redis_client,
                lock_key,
                lock_token,
                lock_lost,
            ):
                await _requeue_after_reanalysis_lock_loss(
                    redis_client,
                    payload,
                    processed_at,
                )
                return

            async with async_session() as db:
                result = await reanalyse_conversation(
                    db,
                    payload.conversation_id,
                    llm_service,
                    embedding_service,
                )
            if not await _owns_reanalysis_lock(
                redis_client,
                lock_key,
                lock_token,
                lock_lost,
            ):
                await _requeue_after_reanalysis_lock_loss(
                    redis_client,
                    payload,
                    processed_at,
                )
                return
            if not result.found:
                logger.warning(
                    f"[Reanalysis] Conversation {payload.conversation_id} not found"
                )
                return

            latest_raw = await redis_client.get(latest_key)
            if latest_raw is None:
                return
            if isinstance(latest_raw, bytes):
                latest_raw = latest_raw.decode()
            try:
                latest_at = _parse_aware_datetime(latest_raw)
            except (TypeError, ValueError):
                logger.warning(
                    f"[Reanalysis] Ignoring invalid latest marker for "
                    f"{payload.conversation_id}"
                )
                return

            if latest_at <= processed_at:
                await redis_client.eval(
                    _DELETE_LATEST_IF_UNCHANGED_SCRIPT,
                    1,
                    latest_key,
                    latest_raw,
                )
                return
            if run_index == MAX_REANALYSES_PER_LOCK - 1:
                latest_payload = ReanalysisPayload(
                    payload.conversation_id,
                    latest_at,
                )
                await redis_client.lpush("queue:reanalysis", latest_payload.to_json())
                return
            processed_at = latest_at

    except asyncio.CancelledError:
        await redis_client.lpush("queue:reanalysis", current_payload)
        raise
    except Exception as exc:
        logger.exception(
            f"[Reanalysis] Failed conversation {payload.conversation_id}: {exc}"
        )
        await push_reanalysis_to_dead_letter(
            redis_client,
            current_payload,
            str(exc),
            attempts=getattr(exc, "attempts", payload.attempts),
            conversation_id=payload.conversation_id,
        )
    finally:
        if renewal_task is not None:
            renewal_task.cancel()
            with suppress(asyncio.CancelledError):
                await renewal_task
        if lock_acquired:
            try:
                await redis_client.eval(
                    _RELEASE_LOCK_SCRIPT,
                    1,
                    lock_key,
                    lock_token,
                )
            except Exception:
                logger.exception(f"[Reanalysis] Failed to release lock {lock_key}")


async def process_reanalysis(redis_client: redis.Redis):
    """Consume corrected conversations and rebuild their derived memory."""
    llm_service = get_llm_analysis_service()
    embedding_service = get_embedding_service()

    while not shutdown_event.is_set():
        result = await redis_client.brpop("queue:reanalysis", timeout=2)
        if result is None:
            continue
        _, payload = result
        await _process_reanalysis_payload(
            redis_client,
            payload,
            llm_service,
            embedding_service,
        )


async def _enqueue_voice_request(redis_client: redis.Redis, segment_id: uuid.UUID, text: str):
    """Queue a segment that addresses Echo by name for the voice worker.

    Never fails the STT step: the transcription is already committed.
    """
    if find_wake(text) is None:
        return
    try:
        await redis_client.lpush(VOICE_QUEUE, str(segment_id))
        logger.info(f"Voice request detected in segment {segment_id}")
    except Exception:
        logger.exception(f"Could not queue voice request for segment {segment_id}")


async def _claim_stt_audio(db, redis_client: redis.Redis, segment_id: uuid.UUID):
    result = await db.execute(
        select(Segment).where(Segment.id == segment_id).with_for_update()
    )
    segment = result.scalar_one_or_none()
    if segment is None:
        logger.warning(f"Segment {segment_id} not found")
        return None

    segment.transcription_status = "processing"
    audio_path_value = segment.audio_path
    if not audio_path_value:
        error = "Audio path missing"
        logger.error(f"{error} for segment {segment_id}")
        segment.transcription_status = "failed"
        await db.commit()
        await push_to_dead_letter(redis_client, segment_id, "stt", error)
        return None

    audio_path = Path(audio_path_value)
    try:
        audio_data = audio_path.read_bytes()
    except FileNotFoundError:
        error = "Audio file not found"
        logger.error(f"{error}: {audio_path}")
        segment.transcription_status = "failed"
        await db.commit()
        await push_to_dead_letter(redis_client, segment_id, "stt", error)
        return None
    except OSError as exc:
        logger.error(f"Unable to read audio file {audio_path}: {exc}")
        segment.transcription_status = "failed"
        await db.commit()
        await push_to_dead_letter(redis_client, segment_id, "stt", str(exc))
        return None

    await db.commit()
    return segment, audio_data


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
            segment = None
            try:
                claimed_audio = await _claim_stt_audio(db, redis_client, segment_id)
                if claimed_audio is None:
                    continue
                segment, audio_data = claimed_audio

                # Decode ADPCM to WAV for STT
                wav_data = adpcm_to_wav(audio_data)

                # Known names and topics, as a prompt or keyterms depending on the provider
                stt_context = await build_stt_context(db, segment.user_id)

                stt_result = await retry_with_backoff(
                    stt_service.transcribe,
                    wav_data,
                    language=settings.stt_language,
                    prompt=stt_context.prompt or None,
                    keyterms=stt_context.keyterms,
                    operation_name=f"STT segment {segment_id}",
                )

                # Post-process: clean artifacts and normalize
                cleaned_text = clean_transcription(stt_result.text)

                # Classify speaker based on audio energy
                speaker = await classify_segment(
                    db, segment.user_id, segment.audio_energy
                )
                segment.speaker = speaker

                # Prefix transcription with speaker tag
                cleaned_text = f"{speaker_prefix(speaker)}{cleaned_text}"

                # Save transcription
                transcription = Transcription(
                    segment_id=segment_id,
                    text=cleaned_text,
                    language=stt_result.language,
                    confidence=stt_result.confidence,
                    # The service that ran (stt_model would name OpenAI's model
                    # even when Deepgram transcribed)
                    stt_provider=stt_service.provider,
                    stt_model=stt_service.model,
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
                    await _enqueue_voice_request(redis_client, segment_id, cleaned_text)
                else:
                    logger.info(
                        f"STT completed but skipping analysis (trivial): "
                        f"segment {segment_id} text='{cleaned_text}'"
                    )

            except RetryExhaustedError as e:
                logger.error(f"STT failed permanently for segment {segment_id}: {e}")
                if segment is not None:
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
                if segment is not None:
                    segment.transcription_status = "failed"
                    await db.commit()
                await push_to_dead_letter(redis_client, segment_id, "stt", str(e))


async def process_analysis(redis_client: redis.Redis):
    """Process analysis queue: extract entities, group conversations, create embeddings."""
    llm_service = get_llm_analysis_service()
    embedding_service = get_embedding_service()
    pipeline = AnalysisPipeline(llm_service, embedding_service)

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

                analysis_result = await pipeline.analyze_segment(db, segment)
                logger.info(
                    f"Analysis completed for segment {segment_id}: "
                    f"{analysis_result.extracted_entity_count} entities, "
                    f"{analysis_result.chunk_count} chunks"
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
        asyncio.create_task(process_reanalysis(redis_client), name="reanalysis_worker"),
        asyncio.create_task(run_retention_loop(shutdown_event), name="retention_worker"),
        asyncio.create_task(run_summary_loop(shutdown_event), name="summary_worker"),
        asyncio.create_task(run_digest_loop(shutdown_event), name="digest_worker"),
        asyncio.create_task(
            process_voice_queue(redis_client, shutdown_event), name="voice_worker"
        ),
    ]

    # Wait for shutdown signal
    await shutdown_event.wait()
    logger.info(f"[Shutdown] Waiting up to {SHUTDOWN_TIMEOUT_S}s for tasks to finish...")

    # Let in-progress items finish (loops exit between items); cancel after the timeout
    results = await stop_tasks(tasks, timeout=SHUTDOWN_TIMEOUT_S)

    for task, result in zip(tasks, results):
        if isinstance(result, Exception) and not isinstance(result, asyncio.CancelledError):
            logger.error(f"[Shutdown] Task {task.get_name()} ended with error: {result}")

    await redis_client.aclose()
    logger.info("[Shutdown] Worker stopped cleanly.")


if __name__ == "__main__":
    asyncio.run(main())
