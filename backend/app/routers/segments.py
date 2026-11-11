import hashlib
import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, File, Header, HTTPException, Request, UploadFile, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.config import settings
from app.core.database import get_db
from app.core.logging import remember_correlation
from app.core.rate_limit import limiter
from app.models.segment import Segment
from app.schemas.transcription import (
    TranscriptionCorrectionRequest,
    TranscriptionCorrectionResponse,
)
from app.services.transcription_editor import (
    TranscriptionConflictError,
    TranscriptionNotFoundError,
    TranscriptionValidationError,
    edit_transcription,
)

router = APIRouter(prefix="/segments", tags=["segments"])
logger = logging.getLogger(__name__)
MAX_AUDIO_BYTES = 5 * 1024 * 1024


async def _read_audio_limited(audio: UploadFile) -> bytes:
    """Read at most the accepted audio size plus one byte, without buffering a larger upload."""
    audio_data = await audio.read(MAX_AUDIO_BYTES + 1)
    if not audio_data:
        raise HTTPException(status_code=400, detail="Empty audio file")
    if len(audio_data) > MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Audio file too large ({len(audio_data)} bytes). Maximum is 5MB.",
        )
    return audio_data


async def _queue_stt_segment(request: Request, segment_id: uuid.UUID) -> None:
    redis_client = request.app.state.redis
    await remember_correlation(redis_client, "segment", segment_id)
    await redis_client.lpush("queue:stt", str(segment_id))


class SegmentResponse(BaseModel):
    id: uuid.UUID
    received_at: datetime
    duration_ms: int
    transcription_status: str

    model_config = {"from_attributes": True}


class RecentSegmentResponse(BaseModel):
    id: uuid.UUID
    received_at: datetime
    recorded_at: datetime
    duration_ms: int
    transcription_status: str
    text: str | None
    speaker: str | None
    conversation_id: uuid.UUID | None


@router.get("/recent", response_model=list[RecentSegmentResponse])
async def list_recent_segments(
    limit: int = 50,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Return recent Segments immediately, including pending Transcriptions."""
    from app.models.transcription import Transcription

    transcription_text = (
        select(Transcription.text)
        .where(Transcription.segment_id == Segment.id)
        .order_by(Transcription.created_at.desc())
        .limit(1)
        .scalar_subquery()
    )
    result = await db.execute(
        select(Segment, transcription_text.label("text"))
        .where(Segment.user_id == user_id)
        .order_by(Segment.received_at.desc())
        .limit(max(1, min(limit, 100)))
    )
    return [
        RecentSegmentResponse(
            id=segment.id,
            received_at=segment.received_at,
            recorded_at=segment.recorded_at,
            duration_ms=segment.duration_ms,
            transcription_status=segment.transcription_status,
            text=text,
            speaker=segment.speaker,
            conversation_id=segment.conversation_id,
        )
        for segment, text in result.all()
    ]


@router.patch(
    "/{segment_id}/transcription",
    response_model=TranscriptionCorrectionResponse,
    status_code=status.HTTP_202_ACCEPTED,
    responses={status.HTTP_200_OK: {"model": TranscriptionCorrectionResponse}},
)
async def correct_transcription(
    segment_id: uuid.UUID,
    correction: TranscriptionCorrectionRequest,
    request: Request,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await edit_transcription(
            db,
            user_id=user_id,
            segment_id=segment_id,
            text=correction.text,
            speaker=correction.speaker,
        )
    except TranscriptionNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Segment not found") from exc
    except TranscriptionConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except TranscriptionValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    response_payload = TranscriptionCorrectionResponse(
        segment_id=result.segment_id,
        transcription_id=result.transcription_id,
        text=result.text,
        speaker_label=result.speaker_label,
        updated_at=result.updated_at,
        reanalysis_status="unchanged" if not result.changed else "queued",
    )
    response_content = response_payload.model_dump(mode="json")
    if not result.changed:
        return JSONResponse(status_code=status.HTTP_200_OK, content=response_content)

    queue_status = "queued"
    queue_payload = json.dumps(
        {
            "conversation_id": str(result.conversation_id),
            "requested_at": response_content["updated_at"],
        }
    )
    try:
        redis_client = request.app.state.redis
        await redis_client.set(
            f"reanalysis:latest:{result.conversation_id}",
            response_content["updated_at"],
        )
        await redis_client.lpush("queue:reanalysis", queue_payload)
    except Exception:
        logger.exception(
            "Failed to enqueue transcript reanalysis for conversation %s",
            result.conversation_id,
        )
        queue_status = "queue_failed"

    response_content["reanalysis_status"] = queue_status
    return JSONResponse(status_code=status.HTTP_202_ACCEPTED, content=response_content)


@router.post("", response_model=SegmentResponse, status_code=status.HTTP_201_CREATED)
@limiter.limit("60/minute")
async def ingest_segment(
    request: Request,
    audio: UploadFile = File(..., description="ADPCM audio file"),
    recorded_at: datetime = Header(..., alias="X-Recorded-At"),
    duration_ms: int = Header(..., alias="X-Duration-Ms"),
    silence_before_ms: int | None = Header(None, alias="X-Silence-Before-Ms"),
    audio_energy: int | None = Header(None, alias="X-Audio-Energy"),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Receive an ADPCM audio segment from the device.

    The device sends audio chunks every 5-10 seconds of detected speech.
    Each chunk is stored and queued for STT processing.

    Idempotent: if the same audio content for the same recorded_at is sent twice
    (e.g., device retry), the duplicate is detected and the original is returned.
    """
    audio_data = await _read_audio_limited(audio)

    # --- Idempotency check ---
    # Hash audio content + recorded_at to detect device retries
    idempotency_hash = hashlib.sha256(
        audio_data + recorded_at.isoformat().encode()
    ).hexdigest()

    existing = await db.execute(
        select(Segment).where(
            Segment.user_id == user_id,
            Segment.audio_hash == idempotency_hash,
        )
    )
    existing_segment = existing.scalar_one_or_none()
    if existing_segment is not None:
        if existing_segment.transcription_status == "pending":
            await _queue_stt_segment(request, existing_segment.id)
        # Return the existing segment — no duplicate processing
        return SegmentResponse(
            id=existing_segment.id,
            received_at=existing_segment.received_at,
            duration_ms=existing_segment.duration_ms,
            transcription_status=existing_segment.transcription_status,
        )

    # Store audio file
    segment_id = uuid.uuid4()
    audio_dir = Path(settings.audio_storage_path) / str(user_id)
    audio_dir.mkdir(parents=True, exist_ok=True)
    audio_path = audio_dir / f"{segment_id}.adpcm"
    audio_path.write_bytes(audio_data)

    # Create segment record
    segment = Segment(
        id=segment_id,
        user_id=user_id,
        received_at=datetime.now(timezone.utc),
        recorded_at=recorded_at,
        duration_ms=duration_ms,
        audio_path=str(audio_path),
        audio_size_bytes=len(audio_data),
        silence_before_ms=silence_before_ms,
        audio_energy=audio_energy,
        audio_hash=idempotency_hash,
        transcription_status="pending",
    )
    db.add(segment)
    # Commit before enqueue so the worker can see the row (avoids race with BRPOP).
    await db.commit()

    # Queue for STT processing via Redis (shared pool)
    await _queue_stt_segment(request, segment_id)

    return SegmentResponse(
        id=segment.id,
        received_at=segment.received_at,
        duration_ms=segment.duration_ms,
        transcription_status=segment.transcription_status,
    )
