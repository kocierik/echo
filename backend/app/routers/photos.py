"""Wearable camera: photo requests, image upload and download, and the wearable's commands.

The app long-polls `GET /device/commands` while the wearable is connected and relays
each TAKE_PHOTO; it uploads the JPEG with `PUT /photos/{id}/image`, or reports why the
wearable could not take it with `POST /photos/{id}/failure`. See app/services/photos.py.
"""

import hashlib
import uuid
from datetime import datetime
from typing import Literal

from fastapi import (
    APIRouter,
    Depends,
    File,
    Header,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
    status,
)
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import undefer

from app.actions.voice import get_or_create_voice_session
from app.core.auth import get_current_user_id
from app.core.config import settings
from app.core.database import get_db
from app.core.rate_limit import limiter
from app.models.photo import Photo
from app.services.photos import (
    FAILURE_REASONS,
    PHOTO_QUEUE,
    accepts_image,
    append_message,
    fail_photo,
    is_jpeg,
    lock_chat_session,
    request_photo,
    store_image,
    take_device_commands,
)

router = APIRouter(tags=["photos"])

MAX_WAIT_S = 25


class PhotoRequest(BaseModel):
    question: str | None = Field(default=None, max_length=500)
    # "app" (the camera button in Ask) or "button" (the wearable's own button: the user is
    # not looking at the phone, so the answer is notified)
    source: Literal["app", "button"] = "app"
    # The chat the photo is asked from; the "Voice requests" chat when omitted
    chat_session_id: uuid.UUID | None = None


class PhotoFailure(BaseModel):
    reason: str


class PhotoOut(BaseModel):
    id: uuid.UUID
    status: str
    source: str
    question: str | None
    answer: str | None
    error: str | None
    captured_at: datetime | None
    chat_session_id: uuid.UUID | None
    conversation_id: uuid.UUID | None

    model_config = {"from_attributes": True}


async def _own_photo(
    db: AsyncSession, photo_id: uuid.UUID, user_id: uuid.UUID, *, lock: bool = False
) -> Photo:
    query = select(Photo).where(Photo.id == photo_id, Photo.user_id == user_id)
    if lock:
        query = query.with_for_update()
    photo = (await db.execute(query)).scalar_one_or_none()
    if photo is None:
        raise HTTPException(status_code=404, detail="Photo not found")
    return photo


@router.post("/photos", response_model=PhotoOut, status_code=status.HTTP_201_CREATED)
@limiter.limit("30/minute")
async def create_photo_request(
    request: Request,
    body: PhotoRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The app's camera button: a request the app then sends to the wearable itself.

    The question (or a camera mark) is added to the chat now; the answer follows with
    the photo, in the chat it was asked from or in "Voice requests".
    """
    if body.chat_session_id is not None:
        session = await lock_chat_session(db, body.chat_session_id)
        if session is None or session.user_id != user_id:
            raise HTTPException(status_code=404, detail="Chat session not found")
    else:
        session = await get_or_create_voice_session(db, user_id)
        await db.flush()
    photo = request_photo(
        db, user_id, source=body.source, chat_session_id=session.id, question=body.question
    )
    await append_message(
        db,
        session.id,
        {"role": "user", "content": photo.question or "📷", "photo_id": str(photo.id)},
    )
    await db.commit()
    return photo


@router.get("/photos/{photo_id}", response_model=PhotoOut)
async def get_photo(
    photo_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    return await _own_photo(db, photo_id, user_id)


@router.put("/photos/{photo_id}/image", response_model=PhotoOut)
@limiter.limit("30/minute")
async def upload_photo_image(
    request: Request,
    response: Response,
    photo_id: uuid.UUID,
    image: UploadFile = File(..., description="JPEG from the wearable"),
    captured_at: datetime = Header(..., alias="X-Captured-At"),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Store the JPEG and queue it for the vision model.

    Idempotent: the same image again returns the stored photo, so the app can retry
    and only then tell the wearable to free it.
    """
    data = await image.read(settings.photo_max_bytes + 1)
    if len(data) > settings.photo_max_bytes:
        raise HTTPException(status_code=413, detail="Photo too large")
    if not is_jpeg(data):
        raise HTTPException(status_code=400, detail="Not a JPEG image")

    photo = await _own_photo(db, photo_id, user_id, lock=True)
    if photo.image_sha256 is not None:
        if photo.image_sha256 != hashlib.sha256(data).hexdigest():
            raise HTTPException(status_code=409, detail="This photo already has an image")
        response.status_code = status.HTTP_200_OK
        return photo
    if not accepts_image(photo):
        raise HTTPException(status_code=409, detail=f"Photo is {photo.status}")

    store_image(photo, data, captured_at)
    await db.commit()
    await request.app.state.redis.lpush(PHOTO_QUEUE, str(photo.id))
    response.status_code = status.HTTP_201_CREATED
    return photo


@router.post("/photos/{photo_id}/failure", response_model=PhotoOut)
async def report_photo_failure(
    photo_id: uuid.UUID,
    body: PhotoFailure,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The wearable could not take the photo: the user is told why in the chat."""
    if body.reason not in FAILURE_REASONS:
        raise HTTPException(status_code=422, detail="Unknown reason")
    photo = await _own_photo(db, photo_id, user_id, lock=True)
    if photo.status == "requested":
        await fail_photo(db, photo, body.reason)
        await db.commit()
    return photo


@router.get("/photos/{photo_id}/image")
async def get_photo_image(
    photo_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Photo)
        .options(undefer(Photo.image))
        .where(Photo.id == photo_id, Photo.user_id == user_id)
    )
    photo = result.scalar_one_or_none()
    if photo is None or not photo.image:
        raise HTTPException(status_code=404, detail="Photo not found")
    return Response(
        content=photo.image,
        media_type="image/jpeg",
        headers={"Cache-Control": "private, max-age=86400"},
    )


@router.get("/device/commands")
async def device_commands(
    request: Request,
    wait: int = Query(default=0, ge=0, le=MAX_WAIT_S),
    user_id: uuid.UUID = Depends(get_current_user_id),
):
    """Commands for the wearable (TAKE_PHOTO), waiting up to `wait` seconds for one.

    A command is handed out once: the app relays it, then uploads the photo or reports
    the failure. One that is never answered fails after PHOTO_REQUEST_TIMEOUT_S.
    """
    commands = await take_device_commands(request.app.state.redis, user_id, wait)
    return {"commands": commands}
