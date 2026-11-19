"""Signing in: an account's email and password, or Google, give a phone its own API key.

Accounts are made with `make create-user`, from the app (/register, unless closed) or by
signing in with Google for the first time.
"""

import math
import re
import secrets
import uuid
from datetime import datetime
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from app.core.auth import (
    client_address,
    email_failure_key,
    get_current_api_key,
    hash_api_key,
    login_failure_key,
    release_attempt,
    remember_revoked,
    reserve_attempt,
)
from app.core.config import settings
from app.core.database import get_db
from app.models.api_key import ApiKey
from app.models.user import User
from app.services.account_deleter import delete_account
from app.services.google_sign_in import GoogleIdentity, GoogleUnavailableError, verify_id_token
from app.services.google_sign_in import client_ids as google_client_ids
from app.services.language import HEARD_LANGUAGES, MAX_OTHER_LANGUAGES, SUPPORTED_LANGUAGES
from app.services.passwords import (
    DUMMY_PASSWORD_HASH,
    create_google_user,
    create_user,
    hash_password,
    normalize_email,
    verify_password,
)
from app.services.personal import MAX_INSTRUCTIONS

router = APIRouter(prefix="/auth", tags=["auth"])

WRONG_CREDENTIALS = "Wrong email or password."


class PhoneSignIn(BaseModel):
    """The phone a sign-in is for: it gets its own key, named in Devices."""

    device_name: str = Field(min_length=1, max_length=100)
    # "web": the app in a browser (/app), signed in like a phone
    platform: Literal["ios", "android", "web"]

    @field_validator("device_name")
    @classmethod
    def _named(cls, value: str) -> str:
        """A name the Devices list can show: not only spaces."""
        value = value.strip()
        if not value:
            raise ValueError("device_name must not be blank")
        return value


class LoginRequest(PhoneSignIn):
    email: str = Field(min_length=1, max_length=320)
    password: str = Field(min_length=1, max_length=1024)


class RegisterRequest(LoginRequest):
    # The phone's language; one Echo does not transcribe yet falls back to English
    language: str | None = Field(default=None, max_length=20)


class GoogleSignInRequest(PhoneSignIn):
    # The ID token the app got from Google for this person
    id_token: str = Field(min_length=1, max_length=8192)
    # As in RegisterRequest: used only when the account is new
    language: str | None = Field(default=None, max_length=20)


class Me(BaseModel):
    email: str | None
    language: str
    name: str | None = None
    instructions: str | None = None
    # Other languages heard around the user (Profile → Language)
    other_languages: list[str] = []
    # False for an account made with Google: deleting it asks Google, not a password
    has_password: bool = True


class MeUpdate(BaseModel):
    """Only the fields sent change; a blank name removes it."""

    language: Literal[SUPPORTED_LANGUAGES] | None = None  # type: ignore[valid-type]
    # In the user's order; duplicates and the main language are dropped
    other_languages: list[Literal[HEARD_LANGUAGES]] | None = None  # type: ignore[valid-type]
    name: str | None = Field(default=None, max_length=100)
    instructions: str | None = Field(default=None, max_length=MAX_INSTRUCTIONS)


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
    # "full" (phones, scripts) or "read" (connected apps)
    scope: str = "full"
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


async def _forget(request: Request, key: ApiKey) -> None:
    """Remembers a deleted key, so its phone's later requests are not failed attempts."""
    redis = getattr(request.app.state, "redis", None)
    if redis is not None:
        await remember_revoked(redis, key.key_hash)


@router.post("/login", response_model=LoginResponse)
async def login(body: LoginRequest, request: Request, db: AsyncSession = Depends(get_db)):
    """A new key for this phone, shown once. Wrong email and wrong password look the same."""
    redis = getattr(request.app.state, "redis", None)
    email = normalize_email(body.email)
    # Counted before the check (a burst cannot slip under the limit), per client and
    # per account; given back when the password is right
    limits = [login_failure_key(request), email_failure_key(email)]
    if redis is not None:
        for key in limits:
            seconds = await reserve_attempt(redis, key)
            if seconds is not None:
                raise _too_many(seconds)

    user = await db.scalar(select(User).where(User.email == email))
    # An unknown email, or an account made with Google (no password), still costs a
    # password check, so timing tells nothing. Argon2 is slow on purpose: off the event
    # loop, so other requests keep flowing
    valid = await run_in_threadpool(
        verify_password,
        user.password_hash if user and user.password_hash else DUMMY_PASSWORD_HASH,
        body.password,
    )
    valid = valid and bool(user and user.password_hash)
    if user is None or not valid:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=WRONG_CREDENTIALS)
    if redis is not None:
        for key in limits:
            await release_attempt(redis, key)

    return await _sign_in_phone(db, user, body, request)


# Phones signed in to one account at once: the next sign-in signs out the oldest, so
# signing in again and again cannot pile up keys (each with its own rate budget)
MAX_PHONES = 10


async def _sign_in_phone(
    db: AsyncSession, user: User, body: LoginRequest, request: Request
) -> LoginResponse:
    """A new key for this phone, shown once."""
    phones = (await db.scalars(
        select(ApiKey)
        .where(ApiKey.user_id == user.id, ApiKey.platform.is_not(None), ApiKey.scope == "full")
        .order_by(ApiKey.created_at.desc())
    )).all()
    for oldest in phones[MAX_PHONES - 1:]:
        await db.delete(oldest)
        await _forget(request, oldest)
    key = secrets.token_urlsafe(32)
    record = ApiKey(
        user_id=user.id,
        key_hash=hash_api_key(key),
        name=body.device_name,
        platform=body.platform,
    )
    db.add(record)
    await db.flush()
    return LoginResponse(
        api_key=key,
        device_id=str(record.id),
        user=LoginUser(id=str(user.id), email=user.email),
    )


# Accounts made from one address, per hour: a bot cannot make thousands
REGISTRATIONS_PER_HOUR = 5

_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


@router.post("/register", response_model=LoginResponse)
async def register(
    body: RegisterRequest, request: Request, db: AsyncSession = Depends(get_db)
):
    """A new account, and this phone signed in to it. Closed with REGISTRATION_OPEN=false."""
    if not settings.registration_open:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Registration is closed.")
    email = normalize_email(body.email)
    if not _EMAIL.match(email):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Enter a valid email.")
    # MIN_PASSWORD_LENGTH in .env raises it again (temporarily any password)
    if len(body.password) < max(1, settings.min_password_length):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "Enter a password."
                if settings.min_password_length <= 1
                else f"Use at least {settings.min_password_length} characters for the password."
            ),
        )
    await _registration_allowed(request)
    if await db.scalar(select(User.id).where(User.email == email)) is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="An account with this email already exists. Sign in instead.",
        )
    hashed = await run_in_threadpool(hash_password, body.password)
    try:
        user = await create_user(db, email, body.password, password_hash=hashed)
    except ValueError as error:  # registered a moment ago by another request
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="An account with this email already exists. Sign in instead.",
        ) from error
    user.language = _spoken_language(body.language)
    return await _sign_in_phone(db, user, body, request)


def _spoken_language(phone_language: str | None) -> str:
    """The new account's language, from the phone's ("it-IT"); English when Echo does not
    transcribe it yet, the server's default when the phone did not say."""
    if phone_language is None:
        return settings.stt_language
    spoken = phone_language.split("-")[0].split("_")[0].lower()
    return spoken if spoken in SUPPORTED_LANGUAGES else "en"


async def _registration_allowed(request: Request) -> None:
    """Raises when accounts cannot be made from here now (closed, or too many this hour)."""
    if not settings.registration_open:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Registration is closed.")
    redis = getattr(request.app.state, "redis", None)
    if redis is None:
        return
    seconds = await reserve_attempt(
        redis,
        "register:" + client_address(request),
        limit=REGISTRATIONS_PER_HOUR,
        window=3600,
    )
    if seconds is not None:
        minutes = max(1, math.ceil(seconds / 60))
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Too many accounts from here. Try again in {minutes} minutes.",
            headers={"Retry-After": str(seconds)},
        )


async def _google_identity(id_token: str) -> GoogleIdentity:
    """The person behind a Google ID token; 401 for a token we do not accept."""
    try:
        return await run_in_threadpool(verify_id_token, id_token)
    except GoogleUnavailableError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Google could not be reached. Try again in a moment.",
        ) from error
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Google did not confirm who you are."
        ) from error


@router.post("/google", response_model=LoginResponse)
async def sign_in_with_google(
    body: GoogleSignInRequest, request: Request, db: AsyncSession = Depends(get_db)
):
    """A new key for this phone, for the person Google vouches for: their account (found by
    Google id, else by the verified email, which links it), or a new one."""
    if not google_client_ids():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not Found")
    redis = getattr(request.app.state, "redis", None)
    limit = login_failure_key(request)
    if redis is not None:
        seconds = await reserve_attempt(redis, limit)
        if seconds is not None:
            raise _too_many(seconds)
    person = await _google_identity(body.id_token)
    if redis is not None:
        await release_attempt(redis, limit)

    user = await db.scalar(select(User).where(User.google_subject == person.subject))
    if user is None:
        user = await db.scalar(select(User).where(User.email == person.email))
        if user is not None:
            # Google verified the address: the same person as the password account
            user.google_subject = person.subject
    if user is None:
        await _registration_allowed(request)
        try:
            user = await create_google_user(
                db,
                person.email,
                person.subject,
                language=_spoken_language(body.language),
                name=person.given_name,
            )
        except ValueError as error:  # made a moment ago by another request
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This account was just created. Try again.",
            ) from error
    return await _sign_in_phone(db, user, body, request)


@router.get("/me", response_model=Me)
async def read_me(
    current: ApiKey = Depends(get_current_api_key), db: AsyncSession = Depends(get_db)
):
    """The account behind this key: its email, the language it speaks and its name."""
    user = await db.get(User, current.user_id)
    if user is None:  # a key made with make create-key, before any account
        return Me(email=None, language=settings.stt_language)
    return _me(user)


def _me(user: User) -> Me:
    return Me(
        email=user.email, language=user.language, name=user.name,
        instructions=user.instructions, other_languages=list(user.other_languages or []),
        has_password=bool(user.password_hash),
    )


class AccountDeletion(BaseModel):
    """The password, or for an account signed in with Google a fresh Google ID token."""

    password: str | None = Field(default=None, min_length=1, max_length=1024)
    google_id_token: str | None = Field(default=None, min_length=1, max_length=8192)


@router.post("/me/delete", status_code=status.HTTP_204_NO_CONTENT)
async def delete_me(
    body: AccountDeletion,
    request: Request,
    current: ApiKey = Depends(get_current_api_key),
    db: AsyncSession = Depends(get_db),
):
    """Deletes the account and everything Echo keeps of it, once the password confirms it:
    a phone left unlocked cannot do it alone."""
    user = await db.get(User, current.user_id)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This key has no account to delete.",
        )
    redis = getattr(request.app.state, "redis", None)
    # Limited as signing in is: a stolen key cannot try passwords
    limits = [login_failure_key(request), email_failure_key(user.email)]
    if redis is not None:
        for key in limits:
            seconds = await reserve_attempt(redis, key)
            if seconds is not None:
                raise _too_many(seconds)
    if body.google_id_token is not None:
        confirmed = False
        if user.google_subject is not None and google_client_ids():
            try:
                person = await run_in_threadpool(verify_id_token, body.google_id_token)
                confirmed = person.subject == user.google_subject
            except (ValueError, GoogleUnavailableError):
                confirmed = False
        if not confirmed:
            # 403, not 401: the key is good, and the app takes a 401 for a revoked key
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Google did not confirm this account.",
            )
    elif body.password is None or not user.password_hash or not await run_in_threadpool(
        verify_password, user.password_hash, body.password
    ):
        # 403, not 401: the key is good, and the app takes a 401 for a revoked key
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Wrong password.")
    if redis is not None:
        for key in limits:
            await release_attempt(redis, key)

    key_hashes = await delete_account(
        db, redis, user.id, audio_root=Path(settings.audio_storage_path)
    )
    if redis is not None:
        # Its phones' later requests are not failed attempts
        for key_hash in key_hashes:
            await remember_revoked(redis, key_hash)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.patch("/me", response_model=Me)
async def update_me(
    body: MeUpdate,
    current: ApiKey = Depends(get_current_api_key),
    db: AsyncSession = Depends(get_db),
):
    """Change the language this account speaks, or the name the app calls it by."""
    user = await db.get(User, current.user_id)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This key has no account yet: create one with make create-user.",
        )
    if body.language is not None:
        user.language = body.language
    others = body.other_languages if body.other_languages is not None else user.other_languages
    kept = [code for code in dict.fromkeys(others or []) if code != user.language]
    if len(kept) > MAX_OTHER_LANGUAGES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"At most {MAX_OTHER_LANGUAGES} other languages.",
        )
    user.other_languages = kept
    if "name" in body.model_fields_set:
        user.name = (body.name or "").strip() or None
    if "instructions" in body.model_fields_set:
        user.instructions = (body.instructions or "").strip() or None
    await db.commit()
    return _me(user)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    request: Request,
    current: ApiKey = Depends(get_current_api_key),
    db: AsyncSession = Depends(get_db),
):
    """Signs this phone out: its key stops working."""
    await _forget(request, current)
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
            scope=key.scope,
            created_at=key.created_at,
            last_used_at=key.last_used_at,
            current=key.id == current.id,
        )
        for key in keys
    ]


MAX_CONNECTED_APPS = 10


class ConnectAppRequest(BaseModel):
    name: str = Field(min_length=1, max_length=60)


class ConnectedApp(BaseModel):
    id: str
    name: str
    # Shown once: only its hash is kept
    api_key: str


@router.post(
    "/connected-apps", response_model=ConnectedApp, status_code=status.HTTP_201_CREATED
)
async def connect_app(
    body: ConnectAppRequest,
    current: ApiKey = Depends(get_current_api_key),
    db: AsyncSession = Depends(get_db),
):
    """A read-only key for an assistant (Claude, Cursor…): it reads the memory over MCP and
    can do nothing else. Listed with the devices and revoked like them."""
    count = await db.scalar(
        select(func.count())
        .select_from(ApiKey)
        .where(ApiKey.user_id == current.user_id, ApiKey.scope == "read")
    )
    if count >= MAX_CONNECTED_APPS:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"At most {MAX_CONNECTED_APPS} connected apps.",
        )
    key = secrets.token_urlsafe(32)
    record = ApiKey(
        user_id=current.user_id,
        key_hash=hash_api_key(key),
        name=body.name.strip() or "Connected app",
        scope="read",
    )
    db.add(record)
    await db.commit()
    return ConnectedApp(id=str(record.id), name=record.name, api_key=key)


@router.delete("/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_device(
    device_id: uuid.UUID,
    request: Request,
    current: ApiKey = Depends(get_current_api_key),
    db: AsyncSession = Depends(get_db),
):
    """Revokes one of this account's keys; another account's is "not found"."""
    key = await db.get(ApiKey, device_id)
    if key is None or key.user_id != current.user_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Device not found")
    await _forget(request, key)
    await db.delete(key)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
