"""Accounts: Argon2 password hashes, and users created from the command line."""

import pytest

from app.models.user import User
from app.services.passwords import (
    create_user,
    hash_password,
    set_password,
    verify_password,
)
from tests.conftest import TEST_USER_ID


def test_hash_and_verify():
    stored = hash_password("correct horse battery")

    assert verify_password(stored, "correct horse battery") is True
    assert verify_password(stored, "correct horse battery!") is False


def test_verify_rejects_malformed_hash():
    assert verify_password("not-a-hash", "x") is False


async def test_create_user_attaches_to_existing_id(db_session):
    user = await create_user(
        db_session, " Erik@Example.com ", "long enough pw", user_id=TEST_USER_ID
    )

    assert user.id == TEST_USER_ID
    assert user.email == "erik@example.com"
    assert verify_password(user.password_hash, "long enough pw")


async def test_create_user_rejects_duplicate_and_short_password(db_session):
    await create_user(db_session, "erik@example.com", "long enough pw")

    with pytest.raises(ValueError, match="email already exists"):
        await create_user(db_session, "ERIK@example.com", "another long pw")
    with pytest.raises(ValueError, match="at least 10 characters"):
        await create_user(db_session, "ada@example.com", "short")


async def test_set_password_changes_hash(db_session):
    await create_user(db_session, "erik@example.com", "the old password")

    await set_password(db_session, " ERIK@example.com", "the new password")

    user = await db_session.get(User, (await _id(db_session, "erik@example.com")))
    assert verify_password(user.password_hash, "the new password")
    assert not verify_password(user.password_hash, "the old password")


async def test_set_password_unknown_email(db_session):
    with pytest.raises(ValueError, match="no such user"):
        await set_password(db_session, "nobody@example.com", "whatever long")


async def _id(db, email):
    from sqlalchemy import select

    return (await db.execute(select(User.id).where(User.email == email))).scalar_one()
