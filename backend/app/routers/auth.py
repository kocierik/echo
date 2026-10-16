"""Signing in: an account's email and password give a phone its own API key.

There is no sign-up here: accounts are created on the server (`make create-user`).
"""

import math
import secrets
import uuid
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import (
    blocked_for,
    client_failure_key,
    email_failure_key,
    get_current_api_key,
    hash_api_key,
    record_failure,
)
from app.core.database import get_db
from app.models.api_key import ApiKey
from app.models.user import User
from app.services.passwords import DUMMY_PASSWORD_HASH, normalize_email, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])

WRONG_CREDENTIALS = "Wrong email or password."


class LoginRequest(BaseModel):
    email: str = Field(min_length=1, max_length=320)
    password: str = Field(min_length=1, max_length=1024)
    device_name: str = Field(min_length=1, max_length=100)
    platform: Literal["ios", "android"]


class LoginUser(BaseModel):
    id: str
    email: str


class LoginResponse(BaseModel):
    api_key: str
    device_id: str
    user: LoginUser


class SignedInDevice(BaseModel):
    id: str
    name: str
    platform: str | None
    created_at: datetime | None
    last_used_at: datetime | None
    current: bool


def _too_many(seconds: int) -> HTTPException:
    minutes = max(1, math.ceil(seconds / 60))
    unit = "minute" if minutes == 1 else "minutes"
    return HTTPException(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        detail=f"Too many attempts. Try again in {minutes} {unit}.",
        headers={"Retry-After": str(seconds)},
    )


@router.post("/login", response_model=LoginResponse)
async def login(body: LoginRequest, request: Request, db: AsyncSession = Depends(get_db)):
    """A new key for this phone, shown once. Wrong email and wrong password look the same."""
    redis = getattr(request.app.state, "redis", None)
    email = normalize_email(body.email)
    limits = [client_failure_key(request), email_failure_key(email)]
    if redis is not None:
        for key in limits:
            seconds = await blocked_for(redis, key)
            if seconds is not None:
                raise _too_many(seconds)

    user = await db.scalar(select(User).where(User.email == email))
    # An unknown email still costs a password check, so timing tells nothing
    valid = verify_password(user.password_hash if user else DUMMY_PASSWORD_HASH, body.password)
    if user is None or not valid:
        if redis is not None:
            for key in limits:
                await record_failure(redis, key)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=WRONG_CREDENTIALS)

    key = secrets.token_urlsafe(32)
    record = ApiKey(
        user_id=user.id,
        key_hash=hash_api_key(key),
        name=body.device_name.strip(),
        platform=body.platform,
    )
    db.add(record)
    await db.flush()
    return LoginResponse(
        api_key=key,
        device_id=str(record.id),
        user=LoginUser(id=str(user.id), email=user.email),
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    current: ApiKey = Depends(get_current_api_key), db: AsyncSession = Depends(get_db)
):
    """Signs this phone out: its key stops working."""
    await db.delete(current)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/devices", response_model=list[SignedInDevice])
async def list_devices(
    current: ApiKey = Depends(get_current_api_key), db: AsyncSession = Depends(get_db)
):
    """The keys of this account, newest first, without their hashes."""
    keys = (
        await db.scalars(
            select(ApiKey)
            .where(ApiKey.user_id == current.user_id)
            .order_by(ApiKey.created_at.desc())
        )
    ).all()
    return [
        SignedInDevice(
            id=str(key.id),
            name=key.name,
            platform=key.platform,
            created_at=key.created_at,
            last_used_at=key.last_used_at,
            current=key.id == current.id,
        )
        for key in keys
    ]


@router.delete("/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_device(
    device_id: uuid.UUID,
    current: ApiKey = Depends(get_current_api_key),
    db: AsyncSession = Depends(get_db),
):
    """Revokes one of this account's keys; another account's is "not found"."""
    key = await db.get(ApiKey, device_id)
    if key is None or key.user_id != current.user_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Device not found")
    await db.delete(key)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
