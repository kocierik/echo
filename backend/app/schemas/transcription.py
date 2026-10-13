import uuid
from typing import Literal

from pydantic import AwareDatetime, BaseModel, field_validator

SpeakerLabel = Literal["self", "other", "unknown"]
ReanalysisStatus = Literal["queued", "queue_failed", "unchanged"]


class TranscriptionCorrectionRequest(BaseModel):
    text: str
    speaker: SpeakerLabel

    @field_validator("text")
    @classmethod
    def validate_text(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("text must not be empty")
        return value


class TranscriptionCorrectionResponse(BaseModel):
    segment_id: uuid.UUID
    transcription_id: uuid.UUID
    text: str
    speaker_label: SpeakerLabel
    updated_at: AwareDatetime
    reanalysis_status: ReanalysisStatus
