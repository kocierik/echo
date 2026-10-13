import uuid
from datetime import datetime, timedelta, timezone

import pytest

from app.actions.pending import (
    PendingActionExpired,
    PendingActionNotFound,
    PendingActionResolved,
    cancel_pending_action,
    confirm_pending_action,
    create_pending_action,
)
from app.actions.provider import AccountNotConnectedError
from app.models.action_log import ActionLog
from tests.fakes.action_provider import FakeActionProvider


class _Result:
    def __init__(self, obj):
        self._obj = obj

    def scalar_one_or_none(self):
        return self._obj


class FakeSession:
    def __init__(self):
        self.rows = []
        self.target = None

    async def execute(self, stmt):
        return _Result(self.target)

    def add(self, obj):
        self.rows.append(obj)

    async def flush(self):
        pass

    async def commit(self):
        pass


USER = uuid.uuid4()
TOOL = "GMAIL_SEND_EMAIL"
ARGS = {"to": "ada@x.it", "body": "hello"}


async def _make(db):
    action = await create_pending_action(db, USER, None, "chat", TOOL, ARGS, "Send email")
    db.target = action
    return action


async def test_confirm_executes_the_stored_arguments_once():
    db, provider = FakeSession(), FakeActionProvider(connected={"gmail"})
    action = await _make(db)
    result = await confirm_pending_action(db, USER, action.id, provider)
    assert result.ok
    assert action.status == "executed"
    assert provider.executed == [(TOOL, ARGS)]
    logs = [r for r in db.rows if isinstance(r, ActionLog)]
    assert len(logs) == 1 and logs[0].outcome == "ok" and logs[0].toolkit == "gmail"
    with pytest.raises(PendingActionResolved):
        await confirm_pending_action(db, USER, action.id, provider)
    assert len(provider.executed) == 1


async def test_confirm_after_30_minutes_is_expired():
    db, provider = FakeSession(), FakeActionProvider(connected={"gmail"})
    action = await _make(db)
    later = datetime.now(timezone.utc) + timedelta(minutes=31)
    with pytest.raises(PendingActionExpired):
        await confirm_pending_action(db, USER, action.id, provider, now=later)
    assert action.status == "expired"
    assert provider.executed == []


async def test_cancel_never_executes():
    db, provider = FakeSession(), FakeActionProvider(connected={"gmail"})
    action = await _make(db)
    out = await cancel_pending_action(db, USER, action.id)
    assert out.status == "cancelled"
    with pytest.raises(PendingActionResolved):
        await confirm_pending_action(db, USER, action.id, provider)
    assert provider.executed == []


async def test_other_users_action_is_not_found():
    db, provider = FakeSession(), FakeActionProvider(connected={"gmail"})
    action = await _make(db)
    with pytest.raises(PendingActionNotFound):
        await confirm_pending_action(db, uuid.uuid4(), action.id, provider)
    with pytest.raises(PendingActionNotFound):
        await cancel_pending_action(db, uuid.uuid4(), action.id)
    db.target = None
    with pytest.raises(PendingActionNotFound):
        await confirm_pending_action(db, USER, uuid.uuid4(), provider)
    assert provider.executed == []


async def test_failed_execution_is_logged_as_error_and_marked_failed():
    db, provider = FakeSession(), FakeActionProvider(connected=set())
    action = await _make(db)
    result = await confirm_pending_action(db, USER, action.id, provider)
    assert not result.ok and result.error
    assert action.status == "failed"
    logs = [r for r in db.rows if isinstance(r, ActionLog)]
    assert len(logs) == 1 and logs[0].outcome == "error" and logs[0].error
    assert isinstance(AccountNotConnectedError("gmail"), Exception)


async def test_timeout_during_execution_is_unknown_not_failed():
    from app.actions.provider import ActionOutcomeUnknown

    db = FakeSession()
    provider = FakeActionProvider(
        connected={"gmail"}, results={TOOL: ActionOutcomeUnknown("Composio request timed out")}
    )
    action = await _make(db)
    result = await confirm_pending_action(db, USER, action.id, provider)
    assert not result.ok and result.unknown
    assert action.status == "unknown" and action.resolved_at is not None
    (log,) = [r for r in db.rows if isinstance(r, ActionLog)]
    assert log.outcome == "unknown"
