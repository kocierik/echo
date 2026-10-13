"""Unit tests: POST /api/query routes tool requests to the action agent."""

import types
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from app.actions.agent import AgentOutcome
from app.actions.provider import ActionProviderError
from app.models.chat_session import ChatSession
from app.models.pending_action import PendingAction
from app.routers import chat_sessions
from app.routers import query as q
from tests.fakes.action_provider import FakeActionProvider
from tests.mocks import MockLLMService

USER_ID = uuid.UUID("a0000000-0000-0000-0000-000000000001")


class _Result:
    def scalar_one_or_none(self):
        return None


class _Db:
    def __init__(self):
        self.added = []

    async def execute(self, _q):
        return _Result()

    def add(self, obj):
        self.added.append(obj)


class _Redis:
    def __init__(self):
        self.store = {}

    async def get(self, key):
        return self.store.get(key)

    async def set(self, key, value, ex=None):
        self.store[key] = value


class _LLM(MockLLMService):
    def __init__(self, needs=True):
        super().__init__()
        self.needs = needs

    async def complete_json(self, messages, temperature=0.1):
        self.call_log.append(messages)
        if self.needs == "error":
            raise RuntimeError("boom")
        return {"needs_tools": self.needs}


def _request(redis):
    state = types.SimpleNamespace(redis=redis)
    return types.SimpleNamespace(app=types.SimpleNamespace(state=state))


@pytest.fixture
def env(monkeypatch):
    e = types.SimpleNamespace(
        redis=_Redis(),
        db=_Db(),
        llm=_LLM(),
        provider=FakeActionProvider(connected={"gmail"}),
        agent_calls=[],
        rag_calls=[],
    )
    monkeypatch.setattr(q, "get_llm_query_service", lambda: e.llm)
    monkeypatch.setattr(q, "get_embedding_service", lambda: None)
    monkeypatch.setattr(q, "get_action_provider", lambda: e.provider)

    async def fake_agent(db, user_id, request, history, **kw):
        e.agent_calls.append((request, kw))
        return e.outcome

    async def fake_rag(*a, **kw):
        e.rag_calls.append(a)
        return types.SimpleNamespace(context="ctx", sources=[])

    e.outcome = AgentOutcome(answer="Ecco le mail", pending_action=None, executed_tools=[])
    monkeypatch.setattr(q, "run_action_agent", fake_agent)
    monkeypatch.setattr(q, "retrieve_memory_context", fake_rag)
    return e


async def _ask(e, question, session_id=None):
    body = q.QueryRequest(question=question, session_id=session_id)
    return await q.query_memory.__wrapped__(_request(e.redis), body, USER_ID, e.db)


def test_might_need_tools_keywords_and_followup():
    assert q.might_need_tools("riassumimi le ultime mail", [])
    assert q.might_need_tools("Send a Slack message", [])
    assert q.might_need_tools("crea un evento", [])
    assert not q.might_need_tools("Cosa mi ha detto Marco ieri?", [])
    hist = [{"role": "assistant", "content": "ok", "actions": True}]
    assert q.might_need_tools("sì, quello", hist)
    assert not q.might_need_tools("sì, quello", [{"role": "assistant", "content": "ok"}])


@pytest.mark.asyncio
async def test_needs_tools_no_connected_skips_llm():
    llm = _LLM()
    assert await q.needs_tools(llm, "mail?", [], []) is False
    assert llm.call_log == []


@pytest.mark.asyncio
async def test_needs_tools_json_and_errors():
    assert await q.needs_tools(_LLM(True), "mail?", [], ["gmail"]) is True
    assert await q.needs_tools(_LLM(False), "mail?", [], ["gmail"]) is False
    assert await q.needs_tools(_LLM("error"), "mail?", [], ["gmail"]) is False


@pytest.mark.asyncio
async def test_memory_question_never_calls_provider(env, monkeypatch):
    def boom():
        raise AssertionError("provider must not be touched")

    monkeypatch.setattr(q, "get_action_provider", boom)
    res = await _ask(env, "Cosa mi ha detto Marco ieri?")
    assert env.agent_calls == [] and len(env.rag_calls) == 1
    assert res.pending_action is None


@pytest.mark.asyncio
async def test_tool_request_goes_to_agent(env):
    res = await _ask(env, "riassumimi le ultime mail")
    assert res.answer == "Ecco le mail"
    assert res.sources == [] and res.pending_action is None
    assert env.rag_calls == []
    assert env.agent_calls[0][1]["source"] == "chat"
    msgs = env.db.added[0].messages
    assert msgs[1]["actions"] is True and "pending_action" not in msgs[1]
    assert "actions" not in msgs[0]


@pytest.mark.asyncio
async def test_pending_action_returned_and_stored(env):
    pa = PendingAction(
        id=uuid.uuid4(),
        summary="Send email to Bob",
        status="pending",
        expires_at=datetime.now(timezone.utc) + timedelta(minutes=30),
    )
    env.outcome = AgentOutcome(answer="Confirm?", pending_action=pa, executed_tools=[])
    res = await _ask(env, "manda una mail a Bob")
    assert res.pending_action.id == pa.id
    assert res.pending_action.summary == "Send email to Bob"
    stored = env.db.added[0].messages[1]
    assert stored["pending_action"] == {
        "id": str(pa.id),
        "summary": "Send email to Bob",
        "status": "pending",
    }
    assert stored["actions"] is True


@pytest.mark.asyncio
async def test_no_connected_toolkit_runs_rag(env):
    env.provider.connected.clear()
    await _ask(env, "riassumimi le ultime mail")
    assert env.agent_calls == [] and len(env.rag_calls) == 1


@pytest.mark.asyncio
async def test_provider_not_configured_runs_rag(env, monkeypatch):
    def unconfigured():
        raise ActionProviderError("Composio is not configured")

    monkeypatch.setattr(q, "get_action_provider", unconfigured)
    await _ask(env, "riassumimi le ultime mail")
    assert env.agent_calls == [] and len(env.rag_calls) == 1


@pytest.mark.asyncio
async def test_intent_says_memory_runs_rag(env):
    env.llm.needs = False
    await _ask(env, "riassumimi le ultime mail")
    assert env.agent_calls == [] and len(env.rag_calls) == 1


@pytest.mark.asyncio
async def test_followup_after_agent_answer_uses_agent(env):
    sid = str(uuid.uuid4())
    await _ask(env, "riassumimi le ultime mail", sid)
    await _ask(env, "sì, quello di Bob", sid)
    assert len(env.agent_calls) == 2


@pytest.mark.asyncio
async def test_persisted_history_keeps_actions_flag_and_schema_accepts_extras():
    pending = {"id": "1", "summary": "s", "status": "pending"}
    stored = [
        {"role": "assistant", "content": "x", "actions": True, "pending_action": pending}
    ]

    class Db:
        async def execute(self, _q):
            return types.SimpleNamespace(scalar_one_or_none=lambda: stored)

    hist = await q._load_persisted_history(Db(), USER_ID, uuid.uuid4())
    assert hist == [{"role": "assistant", "content": "x", "actions": True}]
    msg = chat_sessions.ChatMessage(**stored[0])
    assert msg.pending_action["summary"] == "s"


def test_chat_session_summary_has_kind_and_voice_sorts_first():
    now = datetime.now(timezone.utc)

    def mk(kind, mins):
        return ChatSession(
            id=uuid.uuid4(), user_id=USER_ID, title="t", messages=[], kind=kind,
            created_at=now, updated_at=now + timedelta(minutes=mins),
        )

    ordered = chat_sessions.order_sessions([mk("chat", 5), mk("voice", 1), mk("chat", 3)])
    assert [s.kind for s in ordered] == ["voice", "chat", "chat"]
    assert ordered[1].updated_at > ordered[2].updated_at
    assert "kind" in chat_sessions.ChatSessionSummary.model_fields


@pytest.mark.parametrize(
    "text", ["send an email to Bob", "read my emails", "controlla le email", "check my e-mail"]
)
def test_might_need_tools_matches_email_spellings(text):
    assert q.might_need_tools(text, [])
