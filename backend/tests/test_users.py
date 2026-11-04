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


async def test_create_user_rejects_duplicate_and_empty_password(db_session):
    await create_user(db_session, "erik@example.com", "long enough pw")

    with pytest.raises(ValueError, match="email already exists"):
        await create_user(db_session, "ERIK@example.com", "another long pw")
    with pytest.raises(ValueError, match="must not be empty"):
        await create_user(db_session, "ada@example.com", "")


async def test_create_user_accepts_a_short_password(db_session):
    # Accounts made from the command line have no minimum; register keeps its own
    user = await create_user(db_session, "ada@example.com", "short")

    assert verify_password(user.password_hash, "short")


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


async def test_create_user_for_an_id_that_has_an_account(db_session):
    await create_user(db_session, "erik@example.com", "long enough pw", user_id=TEST_USER_ID)

    with pytest.raises(ValueError, match="already has an account"):
        await create_user(db_session, "ada@example.com", "long enough pw", user_id=TEST_USER_ID)


async def test_set_password_can_sign_out_every_device(db_session):
    from sqlalchemy import func, select

    from app.models.api_key import ApiKey

    await create_user(db_session, "erik@example.com", "the old password", user_id=TEST_USER_ID)
    owner_keys = select(func.count()).select_from(ApiKey).where(ApiKey.user_id == TEST_USER_ID)
    assert await db_session.scalar(owner_keys) >= 1  # the fixture's key

    signed_out = await set_password(
        db_session, "erik@example.com", "the new password", sign_out_devices=True
    )

    assert signed_out >= 1
    assert await db_session.scalar(owner_keys) == 0


async def test_a_new_account_gets_the_plan_of_the_settings(db_session, monkeypatch):
    from app.core.config import settings

    monkeypatch.setattr(settings, "new_account_plan", "unlimited")
    assert (await create_user(db_session, "erik@example.com", "long enough pw")).plan == (
        "unlimited"
    )

    monkeypatch.setattr(settings, "new_account_plan", "gold")  # no such plan
    assert (await create_user(db_session, "ada@example.com", "long enough pw")).plan == "free"
