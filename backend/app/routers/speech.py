"""Spoken answers in Echo's natural voices (services/speech.py): the plans with
`premium_voice` only; the phone reads with its own voice otherwise."""

import uuid

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.core.rate_limit import limiter
from app.services import speech
from app.services.plans import user_plan

router = APIRouter(prefix="/speech", tags=["speech"])

NOT_IN_PLAN = "Echo's natural voices come with the Plus plan."


class VoiceOut(BaseModel):
    id: str
    description: str


class VoicesOut(BaseModel):
    voices: list[VoiceOut]
    # Whether this account may use them (its plan)
    available: bool


class SpeakIn(BaseModel):
    text: str = Field(min_length=1, max_length=speech.MAX_CHARS)
    voice: str | None = None
    # The answer's language ("it", "en"): a native accent for it
    language: str | None = Field(default=None, max_length=5)


def speaker():
    """Who makes the audio (replaced in the tests)."""
    return speech.get_speech()


@router.get("/voices", response_model=VoicesOut)
async def list_voices(
    user_id: uuid.UUID = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)
):
    plan = await user_plan(db, user_id)
    return VoicesOut(
        voices=[VoiceOut(id=key, description=text) for key, text in speech.VOICES.items()],
        available=bool(plan.premium_voice),
    )


@router.post("", response_class=Response)
@limiter.limit("60/minute")
async def speak(
    request: Request,
    body: SpeakIn,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
    voice_maker=Depends(speaker),
):
    """The text as MP3, in the voice chosen; 403 on a plan without natural voices."""
    plan = await user_plan(db, user_id)
    if not plan.premium_voice:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=NOT_IN_PLAN)
    try:
        audio = await voice_maker.speak(
            body.text.strip(), speech.voice_or_default(body.voice), body.language
        )
    except speech.SpeechError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc))
    return Response(content=audio, media_type="audio/mpeg")
