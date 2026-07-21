import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, File, Header, HTTPException, Request, UploadFile, status
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.config import settings
from app.core.database import get_db
from app.models.segment import Segment

router = APIRouter(prefix="/segments", tags=["segments"])


class SegmentResponse(BaseModel):
    id: uuid.UUID
    received_at: datetime
    duration_ms: int
    transcription_status: str

    model_config = {"from_attributes": True}


@router.post("", response_model=SegmentResponse, status_code=status.HTTP_201_CREATED)
async def ingest_segment(
    request: Request,
    audio: UploadFile = File(..., description="ADPCM audio file"),
    recorded_at: datetime = Header(..., alias="X-Recorded-At"),
    duration_ms: int = Header(..., alias="X-Duration-Ms"),
    silence_before_ms: int | None = Header(None, alias="X-Silence-Before-Ms"),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Receive an ADPCM audio segment from the device.

    The device sends audio chunks every 5-10 seconds of detected speech.
    Each chunk is stored and queued for STT processing.
    """
    # Read audio data
    audio_data = await audio.read()
    if not audio_data:
        raise HTTPException(status_code=400, detail="Empty audio file")

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
        transcription_status="pending",
    )
    db.add(segment)
    # Commit before enqueue so the worker can see the row (avoids race with BRPOP).
    await db.commit()

    # Queue for STT processing via Redis (shared pool)
    redis_client = request.app.state.redis
    await redis_client.lpush("queue:stt", str(segment_id))

    return SegmentResponse(
        id=segment.id,
        received_at=segment.received_at,
        duration_ms=segment.duration_ms,
        transcription_status=segment.transcription_status,
    )
