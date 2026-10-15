"""Known voices: the user's own (recorded for it) and people named in transcripts.

See app/services/voice_profiles.py. Voice fingerprints are biometric data: profiles are
made only by the user and can be deleted here.
"""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.segment import Segment
from app.models.voice_profile import VoiceProfile
from app.services.voice_embedding import get_voice_embedder
from app.services.voice_profiles import (
    assign_voice,
    delete_profile,
    enroll_self,
    list_profiles,
    reject_suggestion,
)

router = APIRouter(tags=["voices"])


class VoiceProfileOut(BaseModel):
    id: uuid.UUID
    name: str
    is_self: bool
    person_id: uuid.UUID | None
    sample_count: int
    updated_at: datetime

    model_config = {"from_attributes": True}


class VoiceProfilesOut(BaseModel):
    # False when the server has no voice model: names cannot be recognised
    fingerprints_enabled: bool
    items: list[VoiceProfileOut]


class EnrollRequest(BaseModel):
    started_at: datetime
    ended_at: datetime


class EnrollOut(BaseModel):
    status: str  # "done", "waiting" or "no_speech"
    segments: int
    profile: VoiceProfileOut | None


class VoiceAssignment(BaseModel):
    is_self: bool = False
    name: str | None = Field(default=None, max_length=200)
    person_id: uuid.UUID | None = None


class VoiceAssignmentOut(BaseModel):
    profile: VoiceProfileOut
    relabelled: int
    learned: bool


@router.get("/voice-profiles", response_model=VoiceProfilesOut)
async def get_voice_profiles(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    profiles = await list_profiles(db, user_id)
    return VoiceProfilesOut(
        fingerprints_enabled=get_voice_embedder() is not None,
        items=[VoiceProfileOut.model_validate(p) for p in profiles],
    )


@router.post("/voice-profiles/self/enroll", response_model=EnrollOut)
async def enroll_own_voice(
    body: EnrollRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The user read a text aloud wearing Echo between the two times: that is their voice.

    "waiting" while those segments are still being transcribed: call again.
    """
    if body.ended_at <= body.started_at:
        raise HTTPException(status_code=422, detail="ended_at must follow started_at")
    result = await enroll_self(db, user_id, body.started_at, body.ended_at)
    return EnrollOut(
        status=result.status,
        segments=result.segments,
        profile=VoiceProfileOut.model_validate(result.profile) if result.profile else None,
    )


@router.delete("/voice-profiles/{profile_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_voice_profile(
    profile_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    profile = await db.get(VoiceProfile, profile_id)
    if profile is None or profile.user_id != user_id:
        raise HTTPException(status_code=404, detail="Voice not found")
    await delete_profile(db, profile)


async def _own_segment(db: AsyncSession, segment_id: uuid.UUID, user_id: uuid.UUID) -> Segment:
    segment = (
        await db.execute(
            select(Segment).where(Segment.id == segment_id, Segment.user_id == user_id)
        )
    ).scalar_one_or_none()
    if segment is None:
        raise HTTPException(status_code=404, detail="Segment not found")
    return segment


@router.post("/segments/{segment_id}/voice", response_model=VoiceAssignmentOut)
async def name_segment_voice(
    segment_id: uuid.UUID,
    body: VoiceAssignment,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Whose voice this is: the user's, one of their people, or a new name. The other
    segments of the conversation with the same voice are labelled too."""
    segment = await _own_segment(db, segment_id, user_id)
    try:
        result = await assign_voice(
            db, segment, is_self=body.is_self, name=body.name, person_id=body.person_id
        )
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return VoiceAssignmentOut(
        profile=VoiceProfileOut.model_validate(result.profile),
        relabelled=result.relabelled,
        learned=result.learned,
    )


@router.post("/segments/{segment_id}/voice/reject", status_code=status.HTTP_204_NO_CONTENT)
async def reject_segment_voice(
    segment_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Not the suggested person."""
    await reject_suggestion(db, await _own_segment(db, segment_id, user_id))
