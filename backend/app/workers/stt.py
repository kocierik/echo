"""STT worker: uploaded segments become transcriptions with a speaker.

`queue:stt` holds segment ids. Each segment's ADPCM audio is decoded and transcribed with
the user's known names and topics as context; the voice fingerprint is computed meanwhile
and decides who spoke (the known voices, else the audio energy). Meaningful text goes on to
`queue:analysis`, and text that addresses Echo by name to `queue:voice`.
"""

import asyncio
import logging
import uuid
from pathlib import Path

import redis.asyncio as redis
from sqlalchemy import select

from app.actions.voice import find_wake
from app.core.database import async_session
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.adpcm_decoder import adpcm_to_wav
from app.services.language import account_language
from app.services.speaker_detector import classify_segment
from app.services.stt_openai import get_stt_service
from app.services.transcription_enhancer import (
    build_stt_context,
    clean_transcription,
    is_meaningful_transcription,
    speaker_prefix,
)
from app.services.voice_embedding import embed_voice
from app.services.voice_profiles import list_profiles, recognize
from app.workers.dead_letter import push_to_dead_letter
from app.workers.retry import RetryExhaustedError, retry_with_backoff
from app.workers.voice_requests import VOICE_QUEUE

logger = logging.getLogger(__name__)

STT_QUEUE = "queue:stt"
ANALYSIS_QUEUE = "queue:analysis"


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


async def process_stt(redis_client: redis.Redis, shutdown_event: asyncio.Event):
    """Process STT queue: transcribe audio segments with context-aware prompting."""
    stt_service = get_stt_service()

    while not shutdown_event.is_set():
        # Blocking pop from Redis queue (short timeout to check shutdown flag)
        result = await redis_client.brpop(STT_QUEUE, timeout=2)
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

                # The voice fingerprint, beside the transcription (adds no delay)
                fingerprint = asyncio.create_task(embed_voice(wav_data))

                # Known names and topics, as a prompt or keyterms depending on the provider
                stt_context = await build_stt_context(db, segment.user_id)

                try:
                    stt_result = await retry_with_backoff(
                        stt_service.transcribe,
                        wav_data,
                        language=await account_language(db, segment.user_id),
                        prompt=stt_context.prompt or None,
                        keyterms=stt_context.keyterms,
                        operation_name=f"STT segment {segment_id}",
                    )
                except BaseException:
                    fingerprint.cancel()
                    raise

                # Post-process: clean artifacts and normalize
                cleaned_text = clean_transcription(stt_result.text)

                # Who spoke: the known voices, else the audio energy
                speaker = None
                embedding = await fingerprint
                if embedding is not None:
                    segment.voice_embedding = embedding
                    profiles = await list_profiles(db, segment.user_id)
                    speaker = recognize(segment, embedding, profiles)
                if speaker is None:
                    speaker = await classify_segment(db, segment.user_id, segment.audio_energy)
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
                    await redis_client.lpush(ANALYSIS_QUEUE, str(segment_id))
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
                await redis_client.lpush(STT_QUEUE, str(segment_id))
                raise

            except Exception as e:
                logger.error(f"STT unexpected error for segment {segment_id}: {e}")
                if segment is not None:
                    segment.transcription_status = "failed"
                    await db.commit()
                await push_to_dead_letter(redis_client, segment_id, "stt", str(e))
