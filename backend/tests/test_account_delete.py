"""Deleting an account takes everything of it: every row with its user id, its audio on
disk and its keys in Redis. Another account's data stays."""

import uuid
from datetime import datetime, timezone

from sqlalchemy import text

from app.core.config import settings
from app.models.person_fact import PersonFact
from app.models.user_fact import UserFact
from app.services.passwords import create_user
from tests.conftest import TEST_API_KEY, TEST_USER_ID
from tests.factories import make_conversation, make_entity

EMAIL = "erik@example.com"
PASSWORD = "correct horse battery"
OTHER = uuid.UUID("b0000000-0000-0000-0000-000000000002")
NOW = datetime.now(timezone.utc)


async def _life_of(db, user_id: uuid.UUID) -> None:
    conversation, (line,) = await make_conversation(db, started_at=NOW, user_id=user_id)
    ada = make_entity(conversation, "person", "Ada", source=line)
    ada.user_id = user_id
    db.add(ada)
    await db.flush()
    db.add(PersonFact(
        user_id=user_id, person_id=ada.id, text="Works at Acme", category="work",
        quote="Ada lavora alla Acme", conversation_id=conversation.id, status="current",
    ))
    db.add(UserFact(user_id=user_id, text="Likes tea", status="kept", source="user"))
    await db.commit()


async def _rows_of(db, user_id: uuid.UUID) -> dict[str, int]:
    tables = (await db.execute(text(
        "SELECT table_name FROM information_schema.columns "
        "WHERE column_name = 'user_id' AND table_schema = 'public'"
    ))).scalars().all()
    counts = {}
    for table in tables:
        found = await db.scalar(
            text(f'SELECT count(*) FROM "{table}" WHERE user_id = :u'), {"u": user_id}
        )
        if found:
            counts[table] = found
    return counts


def _delete(client, password=PASSWORD):
    return client.post(
        "/api/auth/me/delete", json={"password": password}, headers={"X-API-Key": TEST_API_KEY}
    )


async def test_deleting_the_account_leaves_nothing_of_it(client, db_session, tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "audio_storage_path", str(tmp_path))
    await create_user(db_session, EMAIL, PASSWORD, user_id=TEST_USER_ID)
    await create_user(db_session, "ada@example.com", "another one", user_id=OTHER)
    await _life_of(db_session, TEST_USER_ID)
    await _life_of(db_session, OTHER)
    (tmp_path / str(TEST_USER_ID)).mkdir()
    (tmp_path / str(TEST_USER_ID) / "a.adpcm").write_bytes(b"audio")
    (tmp_path / str(OTHER)).mkdir()
    (tmp_path / str(OTHER) / "b.adpcm").write_bytes(b"audio")
    redis = client._transport.app.state.redis
    await redis.set(f"voice:working:{TEST_USER_ID}", "1")
    await redis.set(f"voice:working:{OTHER}", "1")
    others_before = await _rows_of(db_session, OTHER)

    response = await _delete(client)

    assert response.status_code == 204
    db_session.expire_all()
    assert await _rows_of(db_session, TEST_USER_ID) == {}
    assert await db_session.scalar(
        text("SELECT count(*) FROM users WHERE id = :u"), {"u": TEST_USER_ID}
    ) == 0
    assert await _rows_of(db_session, OTHER) == others_before
    assert not (tmp_path / str(TEST_USER_ID)).exists()
    assert (tmp_path / str(OTHER) / "b.adpcm").exists()
    assert await redis.get(f"voice:working:{TEST_USER_ID}") is None
    assert await redis.get(f"voice:working:{OTHER}") is not None
    # The key that asked is gone with the account
    after = await client.get("/api/conversations", headers={"X-API-Key": TEST_API_KEY})
    assert after.status_code == 401


async def test_a_wrong_password_deletes_nothing(client, db_session, tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "audio_storage_path", str(tmp_path))
    await create_user(db_session, EMAIL, PASSWORD, user_id=TEST_USER_ID)
    await _life_of(db_session, TEST_USER_ID)
    before = await _rows_of(db_session, TEST_USER_ID)

    response = await _delete(client, password="not it")

    # Not 401: the app would take it for a revoked key and sign the phone out
    assert response.status_code == 403
    db_session.expire_all()
    assert await _rows_of(db_session, TEST_USER_ID) == before


async def test_a_key_without_an_account_cannot_delete(client, db_session):
    response = await _delete(client)

    assert response.status_code == 409
