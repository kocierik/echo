"""STT worker: uploaded segments become transcriptions with a speaker.

`queue:stt` holds segment ids, and `queue:stt:live` those of speech that just ended, read
first so a request is not transcribed after a backlog the phone uploads. Each segment's
ADPCM audio is decoded and transcribed with the user's known names and topics as context;
the voice fingerprint is computed meanwhile and decides who spoke (the known voices, else
the audio energy). Meaningful text goes on to `queue:analysis`, and text that addresses
Echo by name to `queue:voice`. Live speech whose voice is surely a named person may brief
the phone on them (services/person_brief.py).

Past the plan's monthly budget a segment is marked `deferred` instead (services/plans.py):
its audio is kept and it waits. Deferred segments come back on `queue:stt:deferred`
(workers/deferred.py), read only when `queue:stt` is empty so live speech never waits
behind a backlog; there they use the month's budget only, never the daily allowance, and
a request to Echo said back then is not done now.
"""

import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import redis.asyncio as redis
from sqlalchemy import select, update

from app.actions.voice import find_wake
from app.core.database import async_session
from app.core.logging import restore_correlation_for
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.adpcm_decoder import SAMPLE_RATE, SAMPLE_WIDTH
from app.services.language import account_languages
from app.services.person_brief import brief_who_is_talking, confident_voice
from app.services.plans import may_transcribe
from app.services.retranscription import segment_turns
from app.services.segment_audio import decode_segment, pcm_to_wav, segment_to_wav
from app.services.speaker_detector import classify_segment
from app.services.stt_openai import get_stt_service
from app.services.transcription_enhancer import (
    build_stt_context,
    clean_transcription,
    is_meaningful_transcription,
    speaker_prefix,
)
from app.services.usage import usage_owner
from app.services.voice_embedding import embed_voice, loudest_frames
from app.services.voice_profiles import list_profiles, recognize
from app.workers.dead_letter import push_to_dead_letter
from app.workers.lifecycle import sleep_or_shutdown
from app.workers.retry import RetryExhaustedError, retry_with_backoff
from app.workers.voice_requests import VOICE_QUEUE

logger = logging.getLogger(__name__)

STT_QUEUE = "queue:stt"
# Speech that just ended (routers/segments.py): before the backlog a phone uploads late
LIVE_STT_QUEUE = "queue:stt:live"
# Deferred speech the budget allows again, oldest first
DEFERRED_STT_QUEUE = "queue:stt:deferred"
ANALYSIS_QUEUE = "queue:analysis"
STT_PROCESSING_TIMEOUT = timedelta(minutes=15)
STT_RECOVERY_INTERVAL_S = 30
STT_RECOVERY_BATCH_SIZE = 500


async def recover_stt_queue(
    redis_client: redis.Redis,
    *,
    session_factory=async_session,
    now: datetime | None = None,
) -> int:
    """Requeue pending segments and release STT claims left stale by a worker crash."""
    effective_now = now or datetime.now(timezone.utc)
    if effective_now.tzinfo is None or effective_now.utcoffset() != timedelta(0):
        raise ValueError("now must be UTC-aware")

    async with session_factory() as db:
        await db.execute(
            update(Segment)
            .where(
                Segment.transcription_status == "processing",
                Segment.transcription_started_at.is_not(None),
                Segment.transcription_started_at < effective_now - STT_PROCESSING_TIMEOUT,
            )
            .values(transcription_status="pending", transcription_started_at=None)
        )
        await db.commit()
        pending_ids = list(
            await db.scalars(
                select(Segment.id)
                .where(Segment.transcription_status == "pending")
                .order_by(Segment.recorded_at, Segment.id)
                .limit(STT_RECOVERY_BATCH_SIZE)
            )
        )

    # Existing queue entries are consumed first; once empty, the remaining pending
    # records are restored. Claim-status checks make duplicate IDs safe.
    if (
        not pending_ids
        or await redis_client.llen(STT_QUEUE)
        or await redis_client.llen(LIVE_STT_QUEUE)
    ):
        return 0

    await redis_client.lpush(STT_QUEUE, *(str(segment_id) for segment_id in pending_ids))
    return len(pending_ids)


async def run_stt_recovery_loop(
    redis_client: redis.Redis, shutdown_event: asyncio.Event | None = None
) -> None:
    """Periodically restore pending work when an upload or worker lost its Redis enqueue."""
    while not (shutdown_event and shutdown_event.is_set()):
        try:
            recovered = await recover_stt_queue(redis_client)
            if recovered:
                logger.info("[STT recovery] Queued %s pending segments", recovered)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[STT recovery] Could not restore pending segments")

        if await sleep_or_shutdown(STT_RECOVERY_INTERVAL_S, shutdown_event):
            return


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


async def _brief_known_voice(db, redis_client: redis.Redis, segment, profile) -> None:
    """Who is in front of you. Never fails the STT step: the transcription is committed."""
    try:
        await brief_who_is_talking(db, redis_client, segment, profile)
    except Exception:
        logger.exception(f"Could not brief on the voice of segment {segment.id}")


async def _claim_stt_audio(
    db, redis_client: redis.Redis, segment_id: uuid.UUID, *, late: bool = False
):
    """The segment and its audio, marked processing; None when it is not transcribed now
    (missing, ineligible for this queue, or deferred by the budget)."""
    result = await db.execute(
        select(Segment).where(Segment.id == segment_id).with_for_update()
    )
    segment = result.scalar_one_or_none()
    if segment is None:
        logger.warning(f"Segment {segment_id} not found")
        return None
    expected_status = "deferred" if late else "pending"
    if segment.transcription_status != expected_status:
        # Duplicate queue entries and already-claimed segments are safe to skip.
        logger.info(
            f"Segment {segment_id} is {segment.transcription_status}, "
            f"not {expected_status}: skipped"
        )
        return None
    if not await may_transcribe(db, segment.user_id, late=late):
        if segment.transcription_status != "deferred":
            logger.info(f"Segment {segment_id} deferred: the plan's budget is used")
        segment.transcription_status = "deferred"
        segment.transcription_started_at = None
        await db.commit()
        return None

    segment.transcription_status = "processing"
    segment.transcription_started_at = datetime.now(timezone.utc)
    audio_path_value = segment.audio_path
    if not audio_path_value:
        error = "Audio path missing"
        logger.error(f"{error} for segment {segment_id}")
        segment.transcription_status = "failed"
        segment.transcription_started_at = None
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
        segment.transcription_started_at = None
        await db.commit()
        await push_to_dead_letter(redis_client, segment_id, "stt", error)
        return None
    except OSError as exc:
        logger.error(f"Unable to read audio file {audio_path}: {exc}")
        segment.transcription_status = "failed"
        segment.transcription_started_at = None
        await db.commit()
        await push_to_dead_letter(redis_client, segment_id, "stt", str(exc))
        return None

    await db.commit()
    return segment, audio_data


async def process_stt(redis_client: redis.Redis, shutdown_event: asyncio.Event):
    """Process STT queue: transcribe audio segments with context-aware prompting."""
    stt_service = get_stt_service()

    while not shutdown_event.is_set():
        # Blocking pop from Redis queue (short timeout to check shutdown flag)
        # Live speech first: the deferred queue only when nothing new is waiting
        # (BRPOP takes from the first non-empty list, the sentence just said first)
        result = await redis_client.brpop(
            [LIVE_STT_QUEUE, STT_QUEUE, DEFERRED_STT_QUEUE], timeout=2
        )
        if result is None:
            continue

        queue, segment_id_bytes = result
        late = (queue.decode() if isinstance(queue, bytes) else queue) == DEFERRED_STT_QUEUE
        segment_id = uuid.UUID(segment_id_bytes.decode())
        # The upload's correlation ID (a new one for deferred speech past its key's expiry)
        await restore_correlation_for(redis_client, "segment", segment_id)
        logger.info(f"Processing STT for segment {segment_id}{' (deferred)' if late else ''}")
        usage_owner.set(None)  # until the segment is known

        async with async_session() as db:
            segment = None
            try:
                claimed_audio = await _claim_stt_audio(db, redis_client, segment_id, late=late)
                if claimed_audio is None:
                    continue
                segment, audio_data = claimed_audio
                usage_owner.set(segment.user_id)

                # The wearable's ADPCM or Opus as WAV for STT
                wav_data = segment_to_wav(audio_data)

                # The voice fingerprint of where someone speaks, beside the transcription
                # (adds no delay)
                pcm = decode_segment(audio_data)
                # A check for the log only: it never stops a transcription
                declared = getattr(segment, "duration_ms", 0) or 0
                seconds = len(pcm) / (SAMPLE_RATE * SAMPLE_WIDTH)
                kept = seconds / (declared / 1000) if declared else 1.0
                if kept < 0.9:
                    # The wearable fell behind its microphone: gaps garble the transcription
                    logger.warning(
                        "Segment %s holds %.0f%% of its %d ms: the wearable lost audio",
                        segment.id, kept * 100, segment.duration_ms,
                    )
                fingerprint = asyncio.create_task(embed_voice(pcm_to_wav(loudest_frames(pcm))))

                # Known names and topics, as a prompt or keyterms depending on the provider
                stt_context = await build_stt_context(db, segment.user_id)

                # The language the user speaks, and the others they hear around them
                language, others = await account_languages(db, segment.user_id)
                try:
                    stt_result = await retry_with_backoff(
                        stt_service.transcribe,
                        wav_data,
                        language=language,
                        also=others or None,
                        prompt=stt_context.prompt or None,
                        keyterms=stt_context.keyterms,
                        # Who says each word: several voices in a segment are its turns
                        diarize=True,
                        operation_name=f"STT segment {segment_id}",
                    )
                except BaseException:
                    fingerprint.cancel()
                    raise

                # Post-process: clean artifacts and normalize
                cleaned_text = clean_transcription(stt_result.text)

                # Who spoke: the known voices, else the audio energy
                speaker = None
                known = None
                embedding = await fingerprint
                # Nothing said: noise, whose fingerprint would match anyone
                if embedding is not None and cleaned_text:
                    segment.voice_embedding = embedding
                    profiles = await list_profiles(db, segment.user_id)
                    speaker = recognize(segment, embedding, profiles)
                    known = confident_voice(segment, profiles)
                if speaker is None:
                    speaker = await classify_segment(db, segment.user_id, segment.audio_energy)
                segment.speaker = speaker

                # Prefix transcription with speaker tag
                spoken = cleaned_text
                cleaned_text = f"{speaker_prefix(speaker)}{cleaned_text}"

                # Several voices in the segment: who said what, at once. Best effort: the
                # conversation is read whole again when it closes. Not for a request to
                # Echo: one voice, and its answer would wait for every voice's fingerprint
                turns = None
                words = getattr(stt_result, "words", None) or []
                if spoken and words and find_wake(cleaned_text) is None:
                    try:
                        turns = await segment_turns(db, segment, words, pcm)
                    except Exception:
                        logger.warning("No turns for segment %s", segment_id, exc_info=True)

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
                    turns=turns,
                )
                db.add(transcription)

                # Update segment status
                segment.transcription_status = "completed"
                segment.transcription_started_at = None
                await db.commit()

                # A late "who is in front of you" is noise: live speech only
                if known is not None and not late:
                    await _brief_known_voice(db, redis_client, segment, known)

                # Only queue for analysis if transcription is meaningful
                if is_meaningful_transcription(cleaned_text):
                    await redis_client.lpush(ANALYSIS_QUEUE, str(segment_id))
                    logger.info(
                        f"STT completed for segment {segment_id}: '{cleaned_text[:80]}...'"
                    )
                    if not late:
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
                    segment.transcription_started_at = None
                    await db.commit()
                await push_to_dead_letter(
                    redis_client, segment_id, "stt", str(e.last_error), e.attempts
                )

            except asyncio.CancelledError:
                # Shutdown in progress — requeue the segment
                logger.info(f"[Shutdown] STT interrupted for segment {segment_id}, requeueing")
                if segment is not None:
                    segment.transcription_status = "deferred" if late else "pending"
                    segment.transcription_started_at = None
                    await db.commit()
                await redis_client.lpush(
                    DEFERRED_STT_QUEUE if late else STT_QUEUE, str(segment_id)
                )
                raise

            except Exception as e:
                logger.error(f"STT unexpected error for segment {segment_id}: {e}")
                if segment is not None:
                    segment.transcription_status = "failed"
                    segment.transcription_started_at = None
                    await db.commit()
                await push_to_dead_letter(redis_client, segment_id, "stt", str(e))
