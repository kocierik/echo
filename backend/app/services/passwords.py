"""Account passwords (Argon2id) and the accounts made from the command line.

Registration from the app is open by default (REGISTRATION_OPEN); accounts are also
made on the server (app/cli/users.py).
"""

import uuid

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.api_key import ApiKey
from app.models.user import User

# Registration's minimum is settings.min_password_length (routers/auth.py)

_hasher = PasswordHasher()

# Checked against when the email is unknown, so the answer takes as long as for a real one
DUMMY_PASSWORD_HASH = _hasher.hash("echo-no-such-account")


def normalize_email(email: str) -> str:
    return email.strip().lower()


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    """False for a wrong password and for a hash that is not Argon2."""
    try:
        return _hasher.verify(password_hash, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def _check_length(password: str) -> None:
    # No minimum for accounts made from the command line (register keeps its own)
    if not password:
        raise ValueError("password must not be empty")


def _new_account_plan() -> str:
    """NEW_ACCOUNT_PLAN, when it names a plan; free otherwise."""
    from app.services.plans import plan_names  # plans imports this module

    name = settings.new_account_plan.strip().lower()
    return name if name in plan_names() else "free"


async def create_user(
    db: AsyncSession,
    email: str,
    password: str,
    user_id: uuid.UUID | None = None,
    *,
    password_hash: str | None = None,
) -> User:
    """A new account; `user_id` attaches it to data that already exists (the owner's).
    `password_hash`, when the caller hashed `password` already (off the event loop)."""
    email = normalize_email(email)
    _check_length(password)
    if await db.scalar(select(User.id).where(User.email == email)) is not None:
        raise ValueError("email already exists")
    if user_id is not None and await db.get(User, user_id) is not None:
        raise ValueError(
            "this user already has an account; for another person, leave out the user id"
        )
    user = User(
        id=user_id or uuid.uuid4(),
        email=email,
        password_hash=password_hash or hash_password(password),
        plan=_new_account_plan(),
    )
    db.add(user)
    await db.commit()
    return user


async def set_password(
    db: AsyncSession, email: str, password: str, *, sign_out_devices: bool = False
) -> int:
    """Changes the password; with `sign_out_devices` every key of the account goes too
    (after a suspected leak). Returns how many keys were deleted."""
    _check_length(password)
    user = await db.scalar(select(User).where(User.email == normalize_email(email)))
    if user is None:
        raise ValueError("no such user")
    user.password_hash = hash_password(password)
    signed_out = 0
    if sign_out_devices:
        result = await db.execute(delete(ApiKey).where(ApiKey.user_id == user.id))
        signed_out = result.rowcount or 0
    await db.commit()
    return signed_out
