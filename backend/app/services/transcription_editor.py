import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import cast

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.segment import Segment
from app.models.transcription_edit import TranscriptionEdit
from app.models.transcription_translation import TranscriptionTranslation
from app.schemas.transcription import SpeakerLabel


class TranscriptionNotFoundError(Exception):
    pass


class TranscriptionConflictError(Exception):
    pass


class TranscriptionValidationError(ValueError):
    pass


@dataclass(frozen=True)
class TranscriptionEditResult:
    segment_id: uuid.UUID
    transcription_id: uuid.UUID
    text: str
    speaker_label: SpeakerLabel
    updated_at: datetime
    changed: bool
    conversation_id: uuid.UUID


def _normalize_speaker(speaker: str) -> SpeakerLabel:
    if speaker not in {"self", "other", "unknown"}:
        raise TranscriptionValidationError("speaker must be self, other, or unknown")
    return cast(SpeakerLabel, speaker)


async def edit_transcription(
    db: AsyncSession,
    user_id: uuid.UUID,
    segment_id: uuid.UUID,
    text: str,
    speaker: str,
    now: datetime | None = None,
) -> TranscriptionEditResult:
    normalized_text = text.strip()
    if not normalized_text:
        raise TranscriptionValidationError("text must not be empty")
    normalized_speaker = _normalize_speaker(speaker)
    correction_time = now or datetime.now(timezone.utc)
    if correction_time.tzinfo is None or correction_time.utcoffset() is None:
        raise TranscriptionValidationError("now must be timezone-aware")

    try:
        query = (
            select(Segment)
            .where(Segment.id == segment_id, Segment.user_id == user_id)
            .options(
                selectinload(Segment.transcription),
                selectinload(Segment.conversation),
            )
            .with_for_update()
        )
        segment = (await db.execute(query)).scalar_one_or_none()
        if segment is None:
            raise TranscriptionNotFoundError
        if segment.transcription is None:
            raise TranscriptionConflictError("segment has no transcription")
        if segment.conversation is None:
            raise TranscriptionConflictError("segment has no conversation")

        transcription = segment.transcription
        effective_speaker = transcription.speaker_label or segment.speaker
        speaker_mismatch = (
            transcription.speaker_label is not None
            and transcription.speaker_label != segment.speaker
        )
        if (
            transcription.text == normalized_text
            and effective_speaker == normalized_speaker
            and not speaker_mismatch
        ):
            return TranscriptionEditResult(
                segment_id=segment.id,
                transcription_id=transcription.id,
                text=transcription.text,
                speaker_label=normalized_speaker,
                updated_at=correction_time,
                changed=False,
                conversation_id=segment.conversation.id,
            )

        db.add(
            TranscriptionEdit(
                transcription_id=transcription.id,
                user_id=user_id,
                old_text=transcription.text,
                new_text=normalized_text,
                old_speaker_label=effective_speaker,
                new_speaker_label=normalized_speaker,
                created_at=correction_time,
            )
        )
        if transcription.text != normalized_text:
            transcription.turns = None  # who said what in the old words
            # A translation of the old words would be wrong now
            await db.execute(
                delete(TranscriptionTranslation).where(
                    TranscriptionTranslation.transcription_id == transcription.id
                )
            )
        transcription.text = normalized_text
        transcription.speaker_label = normalized_speaker
        segment.speaker = normalized_speaker
        if normalized_speaker == "self" and effective_speaker != "self":
            # "This is me": the segment's voice refines the user's voice profile
            from app.services.voice_profiles import learn_self

            await learn_self(db, segment)
        segment.conversation.analysis_status = "reprocessing"
        conversation_id = segment.conversation.id

        await db.commit()
        return TranscriptionEditResult(
            segment_id=segment.id,
            transcription_id=transcription.id,
            text=normalized_text,
            speaker_label=normalized_speaker,
            updated_at=correction_time,
            changed=True,
            conversation_id=conversation_id,
        )
    except (TranscriptionNotFoundError, TranscriptionConflictError):
        raise
    except Exception:
        await db.rollback()
        raise
