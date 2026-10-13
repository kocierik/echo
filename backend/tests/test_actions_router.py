import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException

from app.actions.pending import create_pending_action
from app.actions.provider import ActionProviderError, ToolResult
from app.models.action_log import ActionLog
from app.models.chat_session import ChatSession
from app.models.pending_action import PendingAction
from app.routers import actions as r
from tests.fakes.action_provider import FakeActionProvider

USER = uuid.uuid4()
TOOL = "GMAIL_SEND_EMAIL"


class _Scalars:
    def __init__(self, rows):
        self._rows = rows

    def all(self):
        return list(self._rows)


class _Result:
    def __init__(self, rows):
        self._rows = rows

    def scalar_one_or_none(self):
        return self._rows[0] if self._rows else None

    def scalars(self):
        return _Scalars(self._rows)


class FakeDb:
    def __init__(self):
        self.action = None
        self.sessions = {}
        self.rows = []  # results for generic select
        self.commits = 0

    async def execute(self, stmt):
        if self.action is not None and "pending_actions" in str(stmt):
            return _Result([self.action])
        return _Result(self.rows)

    async def get(self, model, pk):
        if model is PendingAction:
            return self.action
        return self.sessions.get(pk)

    def add(self, obj):
        pass

    async def flush(self):
        pass

    async def commit(self):
        self.commits += 1


def _session(messages, kind="chat", user=USER):
    return ChatSession(id=uuid.uuid4(), user_id=user, kind=kind, messages=messages)


async def _pending(db, session=None):
    sid = session.id if session else None
    a = await create_pending_action(db, USER, sid, "chat", TOOL, {"to": "x"}, "Send email")
    db.action = a
    if session:
        db.sessions[session.id] = session
    return a


async def test_list_toolkits():
    out = await r.list_toolkits(
        query=None, user_id=USER, provider=FakeActionProvider(connected={"gmail"})
    )
    assert any(t.slug == "gmail" and t.connected for t in out)


async def test_connect_and_disconnect():
    p = FakeActionProvider(connected={"gmail"})
    assert await r.connect_toolkit("gmail", user_id=USER, provider=p) == {
        "url": "https://connect.test/gmail"
    }
    await r.disconnect_toolkit("gmail", user_id=USER, provider=p)
    assert "gmail" not in p.connected


async def test_provider_error_is_502():
    class Boom(FakeActionProvider):
        async def list_toolkits(self, user_id, query=None):
            raise ActionProviderError("nope")

    with pytest.raises(HTTPException) as e:
        await r.list_toolkits(query=None, user_id=USER, provider=Boom())
    assert e.value.status_code == 502


def test_unconfigured_provider_is_503(monkeypatch):
    def boom():
        raise ActionProviderError("Composio is not configured")

    monkeypatch.setattr(r, "get_action_provider", boom)
    with pytest.raises(HTTPException) as e:
        r._get_provider()
    assert e.value.status_code == 503
    assert e.value.detail == "Composio is not configured"


async def test_confirm_appends_message_and_updates_status():
    db = FakeDb()
    s = _session([{"role": "user", "content": "manda una mail a Ada"}])
    a = await _pending(db, s)
    s.messages = [
        *s.messages,
        {
            "role": "assistant",
            "content": "ok",
            "pending_action": {"id": str(a.id), "status": "pending"},
        },
    ]
    p = FakeActionProvider(connected={"gmail"})
    out = await r.confirm_action(a.id, user_id=USER, db=db, redis_client=None, provider=p)
    assert out == {"status": "executed", "message": "Fatto."}
    assert s.messages[1]["pending_action"]["status"] == "executed"
    last = s.messages[-1]
    assert last["role"] == "assistant" and last["content"] == "Fatto."
    assert datetime.fromisoformat(last["timestamp"]).tzinfo is not None


async def test_confirm_failed_english_message():
    db = FakeDb()
    s = _session([{"role": "user", "content": "please send an email to Ada"}])
    a = await _pending(db, s)
    p = FakeActionProvider(
        connected={"gmail"}, results={TOOL: ToolResult(ok=False, error="boom")}
    )
    out = await r.confirm_action(a.id, user_id=USER, db=db, redis_client=None, provider=p)
    assert out == {"status": "failed", "message": "That didn't work: boom"}


async def test_confirm_without_session():
    db = FakeDb()
    a = await _pending(db)
    out = await r.confirm_action(
        a.id, user_id=USER, db=db, redis_client=None,
        provider=FakeActionProvider(connected={"gmail"}),
    )
    assert out["status"] == "executed" and out["message"] == "Done."


async def test_confirm_error_mapping_and_expired_commits():
    db = FakeDb()
    with pytest.raises(HTTPException) as e:
        await r.confirm_action(
            uuid.uuid4(), user_id=USER, db=db, redis_client=None, provider=FakeActionProvider()
        )
    assert e.value.status_code == 404

    a = await _pending(db)
    a.status = "executed"
    with pytest.raises(HTTPException) as e:
        await r.confirm_action(
            a.id, user_id=USER, db=db, redis_client=None, provider=FakeActionProvider()
        )
    assert e.value.status_code == 409

    a.status = "pending"
    a.expires_at = datetime.now(timezone.utc) - timedelta(minutes=1)
    with pytest.raises(HTTPException) as e:
        await r.confirm_action(
            a.id, user_id=USER, db=db, redis_client=None, provider=FakeActionProvider()
        )
    assert e.value.status_code == 410
    assert db.commits == 1 and a.status == "expired"


async def test_cancel():
    db = FakeDb()
    s = _session([{"role": "user", "content": "send an email"}])
    a = await _pending(db, s)
    out = await r.cancel_action(a.id, user_id=USER, db=db, redis_client=None)
    assert out == {"status": "cancelled"}
    assert s.messages[-1]["content"] == "Cancelled."

    with pytest.raises(HTTPException) as e:
        await r.cancel_action(a.id, user_id=USER, db=db, redis_client=None)
    assert e.value.status_code == 409
    db.action = None
    with pytest.raises(HTTPException) as e:
        await r.cancel_action(uuid.uuid4(), user_id=USER, db=db, redis_client=None)
    assert e.value.status_code == 404


async def test_session_of_other_user_is_untouched():
    db = FakeDb()
    s = _session([{"role": "user", "content": "x"}], user=uuid.uuid4())
    a = await _pending(db, s)
    await r.cancel_action(a.id, user_id=USER, db=db, redis_client=None)
    assert len(s.messages) == 1


async def test_log():
    db = FakeDb()
    now = datetime.now(timezone.utc)
    db.rows = [
        ActionLog(
            user_id=USER, source="chat", toolkit="gmail", tool=TOOL,
            arguments_summary="to=x", outcome="ok", error=None, created_at=now,
        )
    ]
    out = await r.action_log(limit=50, user_id=USER, db=db)
    assert out[0].tool == TOOL and out[0].toolkit == "gmail" and out[0].outcome == "ok"


async def test_voice_updates_filters_by_timestamp():
    db = FakeDb()
    t0 = datetime(2026, 1, 1, 10, 0, tzinfo=timezone.utc)
    s = _session(
        [
            {"role": "assistant", "content": "old", "timestamp": t0.isoformat()},
            {"role": "user", "content": "q", "timestamp": (t0 + timedelta(hours=2)).isoformat()},
            {"role": "assistant", "content": "no ts"},
            {
                "role": "assistant",
                "content": "new",
                "timestamp": (t0 + timedelta(hours=1)).isoformat(),
            },
        ],
        kind="voice",
    )
    db.rows = [s]
    out = await r.voice_updates(
        since=datetime(2026, 1, 1, 10, 30), user_id=USER, db=db  # naive -> UTC
    )
    assert [m["content"] for m in out["messages"]] == ["new"]
    assert out["messages"][0]["session_id"] == str(s.id)
    assert out["now"]

    all_ = await r.voice_updates(since=None, user_id=USER, db=db)
    assert [m["content"] for m in all_["messages"]] == ["old", "new"]

    db.rows = []
    assert (await r.voice_updates(since=None, user_id=USER, db=db))["messages"] == []


async def test_confirm_with_unknown_outcome_tells_the_user_to_check():
    from app.actions.provider import ActionOutcomeUnknown

    db = FakeDb()
    s = _session([{"role": "user", "content": "manda una mail a Ada"}])
    a = await _pending(db, s)
    s.messages = [
        *s.messages,
        {"role": "assistant", "content": "ok", "pending_action": {"id": str(a.id)}},
    ]
    p = FakeActionProvider(
        connected={"gmail"}, results={TOOL: ActionOutcomeUnknown("Composio request timed out")}
    )
    out = await r.confirm_action(a.id, user_id=USER, db=db, redis_client=None, provider=p)
    assert out == {
        "status": "unknown",
        "message": (
            "Non sono riuscito a verificare se è andata a buon fine: "
            "controlla Gmail prima di riprovare."
        ),
    }
    assert a.status == "unknown"
    assert s.messages[1]["pending_action"]["status"] == "unknown"
    assert s.messages[-1]["content"] == out["message"]


# --- R28 ---------------------------------------------------------------------------------


class _Redis:
    def __init__(self):
        self.store = {}
        self.ttl = {}

    async def get(self, key):
        return self.store.get(key)

    async def set(self, key, value, ex=None):
        self.store[key] = value
        self.ttl[key] = ex


async def test_outcome_message_is_flagged_and_added_to_the_redis_context():
    import json

    db = FakeDb()
    s = _session([{"role": "user", "content": "send an email to Ada"}])
    a = await _pending(db, s)
    redis = _Redis()
    history = [{"role": "user", "content": f"q{i}"} for i in range(20)]
    redis.store[f"session:{s.id}"] = json.dumps(history).encode()

    await r.confirm_action(
        a.id, user_id=USER, db=db, redis_client=redis,
        provider=FakeActionProvider(connected={"gmail"}),
    )

    assert s.messages[-1]["outcome"] is True
    stored = json.loads(redis.store[f"session:{s.id}"])
    assert len(stored) == 20  # trimmed like query.py
    assert stored[-1] == {"role": "assistant", "content": "Done.", "actions": True}
    assert stored[0] == {"role": "user", "content": "q1"}
    assert redis.ttl[f"session:{s.id}"] == 30 * 60


async def test_outcome_without_redis_context_or_for_voice_sessions_is_not_cached():
    db = FakeDb()
    redis = _Redis()
    chat = _session([{"role": "user", "content": "send an email"}])
    a = await _pending(db, chat)
    await r.cancel_action(a.id, user_id=USER, db=db, redis_client=redis)
    assert redis.store == {}  # context expired: nothing to append to
    assert chat.messages[-1]["outcome"] is True

    db = FakeDb()
    voice = _session([{"role": "user", "content": "send an email"}], kind="voice")
    a = await _pending(db, voice)
    redis.store[f"session:{voice.id}"] = b"[]"
    await r.cancel_action(a.id, user_id=USER, db=db, redis_client=redis)
    assert redis.store[f"session:{voice.id}"] == b"[]"


async def test_voice_updates_skip_confirm_outcome_messages():
    db = FakeDb()
    t0 = datetime(2026, 1, 1, 10, 0, tzinfo=timezone.utc)
    s = _session(
        [
            {"role": "assistant", "content": "Confirm?", "timestamp": t0.isoformat()},
            {
                "role": "assistant",
                "content": "Done.",
                "timestamp": (t0 + timedelta(minutes=1)).isoformat(),
                "outcome": True,
            },
        ],
        kind="voice",
    )
    db.rows = [s]
    out = await r.voice_updates(since=None, user_id=USER, db=db)
    assert [m["content"] for m in out["messages"]] == ["Confirm?"]


async def test_provider_error_text_is_capped_at_200_chars():
    db = FakeDb()
    s = _session([{"role": "user", "content": "please send an email to Ada"}])
    a = await _pending(db, s)
    p = FakeActionProvider(
        connected={"gmail"}, results={TOOL: ToolResult(ok=False, error="x" * 1000)}
    )
    out = await r.confirm_action(a.id, user_id=USER, db=db, redis_client=None, provider=p)
    assert out["message"] == "That didn't work: " + "x" * 200
    assert s.messages[-1]["content"] == out["message"]
