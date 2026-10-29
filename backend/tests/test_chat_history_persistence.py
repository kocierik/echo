"""Unit tests: chat history is appended to Postgres, never overwritten by Redis context."""

import uuid

import pytest
from fastapi import HTTPException

from app.models.chat_session import ChatSession
from app.services import chat_history as query_module

USER_ID = uuid.UUID("a0000000-0000-0000-0000-000000000001")


class _Result:
    def __init__(self, value):
        self._value = value

    def scalar_one_or_none(self):
        return self._value


class _FakeDb:
    def __init__(self, value=None):
        self.value = value
        self.added = []

    async def execute(self, _query):
        return _Result(self.value)

    def add(self, obj):
        self.added.append(obj)


class _FakeRedis:
    def __init__(self):
        self.store = {}

    async def set(self, key, value, ex=None):
        self.store[key] = value


def _turn(question, answer):
    return [
        {"role": "user", "content": question},
        {"role": "assistant", "content": answer},
    ]


@pytest.mark.asyncio
async def test_new_session_is_created_with_the_turn_and_title():
    db = _FakeDb()
    session_id = str(uuid.uuid4())

    await query_module.persist_chat_session(db, USER_ID, session_id, _turn("Ciao?", "Ciao!"))

    assert len(db.added) == 1
    session = db.added[0]
    assert session.title == "Ciao?"
    assert session.messages == _turn("Ciao?", "Ciao!")


@pytest.mark.asyncio
async def test_existing_session_appends_instead_of_overwriting():
    old_messages = [
        msg for i in range(15) for msg in _turn(f"domanda {i}", f"risposta {i}")
    ]  # 30 messages: more than the Redis cap
    existing = ChatSession(
        id=uuid.uuid4(), user_id=USER_ID, title="t", messages=list(old_messages)
    )
    db = _FakeDb(existing)

    await query_module.persist_chat_session(
        db, USER_ID, str(existing.id), _turn("nuova", "ok")
    )

    assert existing.messages == old_messages + _turn("nuova", "ok")
    assert db.added == []


@pytest.mark.asyncio
async def test_session_of_another_user_is_not_touched():
    existing = ChatSession(id=uuid.uuid4(), user_id=uuid.uuid4(), title="t", messages=[])
    db = _FakeDb(existing)

    with pytest.raises(HTTPException) as exc:
        await query_module.persist_chat_session(
            db, USER_ID, str(existing.id), _turn("q", "a")
        )

    assert exc.value.status_code == 404
    assert existing.messages == []


@pytest.mark.asyncio
async def test_record_turn_updates_redis_context_and_appends_only_new_turn(monkeypatch):
    persisted = []

    async def fake_persist(_db, _user_id, _session_id, new_messages, **_kwargs):
        persisted.append(new_messages)

    monkeypatch.setattr(query_module, "persist_chat_session", fake_persist)
    redis = _FakeRedis()
    history = _turn("vecchia", "risposta")

    await query_module.record_turn(
        redis, _FakeDb(), USER_ID, "sid", history, "nuova", "ok"
    )

    assert history == _turn("vecchia", "risposta") + _turn("nuova", "ok")
    [(question, answer)] = persisted
    # Stored with the time and where it was asked; a typed answer is never notified
    assert question["content"] == "nuova" and question["source"] == "chat"
    assert answer["content"] == "ok" and answer["notify"] is False
    assert question["timestamp"] and answer["timestamp"]
    assert "session:sid" in redis.store


@pytest.mark.asyncio
async def test_persisted_history_is_loaded_when_redis_context_expired():
    stored = [
        {**msg, "timestamp": "2026-10-13T10:00:00Z"}
        for i in range(15)
        for msg in _turn(f"q{i}", f"a{i}")
    ]
    db = _FakeDb(stored)

    history = await query_module.load_persisted_history(db, USER_ID, uuid.uuid4())

    assert len(history) == query_module.MAX_HISTORY_MESSAGES
    assert history[-1] == {"role": "assistant", "content": "a14"}
    assert all(set(msg) == {"role", "content"} for msg in history)


@pytest.mark.asyncio
async def test_missing_persisted_session_gives_empty_history():
    history = await query_module.load_persisted_history(_FakeDb(None), USER_ID, uuid.uuid4())

    assert history == []
