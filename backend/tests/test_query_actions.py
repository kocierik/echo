"""Unit tests: POST /api/query routes tool requests to the action agent."""

import types
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException

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
        self.commits = 0
        self.commit_error = None
        self.events = []  # shared with _Redis: the order of commits and stored responses

    async def execute(self, _q):
        return _Result()

    def add(self, obj):
        self.added.append(obj)

    async def flush(self):
        pass

    async def commit(self):
        if self.commit_error is not None:
            raise self.commit_error
        self.commits += 1
        self.events.append("commit")
        self.committed = list(self.added)

    async def rollback(self):
        # Objects added since the last commit are discarded
        self.added = list(getattr(self, "committed", []))
        self.events.append("rollback")


class _Redis:
    def __init__(self):
        self.store = {}
        self.ttl = {}

    async def get(self, key):
        return self.store.get(key)

    async def set(self, key, value, ex=None, nx=False):
        if nx and key in self.store:
            return None
        self.store[key] = value
        self.ttl[key] = ex
        return True

    async def delete(self, *keys):
        for key in keys:
            self.store.pop(key, None)


class _LLM(MockLLMService):
    """`needs` answers the connected-tools check, `app` the named-app check (G2)."""

    def __init__(self, needs=True, app=True):
        super().__init__()
        self.needs = needs
        self.app = app
        self.app_checks = []

    async def complete_json(self, messages, temperature=0.1):
        self.call_log.append(messages)
        if '"needs_app"' in messages[0].content:
            self.app_checks.append(messages)
            if self.app == "error":
                raise RuntimeError("boom")
            return {"needs_app": self.app}
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


async def _ask(e, question, session_id=None, request_id=None):
    body = q.QueryRequest(
        question=question, session_id=session_id, client_request_id=request_id
    )
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
    await _ask(env, "crea una lista di cose da fare per il trasloco")
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


# --- C1: client_request_id replay / in-flight guard -------------------------------------


@pytest.mark.asyncio
async def test_agent_gets_the_connected_toolkits_without_listing_again(env):
    class CountingProvider(FakeActionProvider):
        listed = 0

        async def list_toolkits(self, user_id, query=None):
            CountingProvider.listed += 1
            return await super().list_toolkits(user_id, query)

    env.provider = CountingProvider(connected={"gmail", "asana"})
    await _ask(env, "riassumimi le ultime mail")
    assert CountingProvider.listed == 0
    assert sorted(env.agent_calls[0][1]["connected_toolkits"]) == ["asana", "gmail"]


@pytest.mark.asyncio
async def test_request_id_replays_the_stored_response(env):
    first = await _ask(env, "riassumimi le ultime mail", request_id="r-1")
    key = f"query:req:{USER_ID}:r-1"
    assert env.redis.ttl[key] == 600
    env.outcome = AgentOutcome(answer="different", pending_action=None, executed_tools=[])
    again = await _ask(env, "riassumimi le ultime mail", request_id="r-1")
    assert again == first
    assert len(env.agent_calls) == 1  # the action did not run twice
    assert len(env.db.added) == 1  # nor was the turn recorded twice


@pytest.mark.asyncio
async def test_request_id_still_processing_is_409(env):
    env.redis.store[f"query:req:{USER_ID}:r-2"] = "processing"
    with pytest.raises(HTTPException) as exc:
        await _ask(env, "riassumimi le ultime mail", request_id="r-2")
    assert exc.value.status_code == 409
    assert exc.value.detail == "Still working on it"
    assert env.agent_calls == []


@pytest.mark.asyncio
async def test_request_id_is_per_user_and_cleared_on_a_memory_path_failure(env, monkeypatch):
    env.redis.store[f"query:req:{uuid.uuid4()}:r-3"] = "processing"

    async def broken_rag(*a, **kw):
        raise RuntimeError("embeddings down")

    monkeypatch.setattr(q, "retrieve_memory_context", broken_rag)
    with pytest.raises(RuntimeError):
        await _ask(env, "Cosa mi ha detto Marco ieri?", request_id="r-3")
    # Nothing ran on the memory path: the client may simply retry
    assert f"query:req:{USER_ID}:r-3" not in env.redis.store


@pytest.mark.asyncio
async def test_without_request_id_nothing_is_stored(env):
    await _ask(env, "riassumimi le ultime mail")
    assert not [k for k in env.redis.store if k.startswith("query:req:")]


# --- I6: connected apps unreachable / app not connected ---------------------------------


@pytest.mark.asyncio
async def test_unreachable_connected_apps_get_an_explicit_answer(env):
    class Down(FakeActionProvider):
        async def connected_toolkits(self, user_id):
            raise ActionProviderError("Composio request timed out")

    env.provider = Down()
    res = await _ask(env, "riassumimi le ultime mail di oggi")
    assert res.answer == (
        "Non riesco a raggiungere le app collegate in questo momento. Riprova tra poco."
    )
    assert env.agent_calls == [] and env.rag_calls == []
    stored = env.db.added[0].messages[1]
    assert stored["content"] == res.answer and stored["actions"] is True


@pytest.mark.asyncio
async def test_unreachable_answer_in_english(env):
    class Down(FakeActionProvider):
        async def connected_toolkits(self, user_id):
            raise ActionProviderError("boom")

    env.provider = Down()
    res = await _ask(env, "Send a Slack message to the team")
    assert res.answer == "I couldn't reach your connected apps right now. Try again in a moment."


@pytest.mark.asyncio
async def test_named_app_not_connected_is_said_not_answered_from_memory(env):
    env.provider = FakeActionProvider(connected={"slack"})
    res = await _ask(env, "riassumimi le ultime mail di oggi")
    assert res.answer == (
        "Gmail non è collegato. Collegalo da Impostazioni → Automazioni → Integrazioni."
    )
    assert env.agent_calls == [] and env.rag_calls == []
    assert env.db.added[0].messages[1]["actions"] is True


@pytest.mark.asyncio
async def test_named_app_with_nothing_connected(env):
    env.provider.connected.clear()
    res = await _ask(env, "What's on my calendar tomorrow?")
    assert res.answer == (
        "Google Calendar isn't connected. Connect it in Settings → Automations → Integrations."
    )
    assert env.agent_calls == [] and env.rag_calls == []


# --- G2: "{App} isn't connected" only when the request really needs the app -------------

_AGENDA = "What was on the agenda of yesterday's meeting?"


@pytest.mark.asyncio
async def test_agenda_question_with_calendar_not_connected_is_answered_from_memory(env):
    env.llm.app = False
    env.llm.needs = False
    res = await _ask(env, _AGENDA)
    assert "isn't connected" not in res.answer
    assert env.agent_calls == [] and len(env.rag_calls) == 1
    check = env.llm.app_checks[0]
    assert "Google Calendar" in check[0].content
    assert check[-1].content == _AGENDA


@pytest.mark.asyncio
async def test_agenda_question_with_nothing_connected_is_answered_from_memory(env):
    env.provider.connected.clear()
    env.llm.app = False
    res = await _ask(env, _AGENDA)
    assert "isn't connected" not in res.answer
    assert env.agent_calls == [] and len(env.rag_calls) == 1
    assert len(env.llm.app_checks) == 1


@pytest.mark.asyncio
async def test_calendar_request_with_calendar_not_connected_says_so(env):
    res = await _ask(env, "aggiungi un evento domani alle 10")
    assert res.answer == (
        "Google Calendar non è collegato. Collegalo da Impostazioni → Automazioni → Integrazioni."
    )
    assert env.agent_calls == [] and env.rag_calls == []
    assert len(env.llm.app_checks) == 1


@pytest.mark.asyncio
async def test_app_check_error_means_memory_answer(env):
    env.provider.connected.clear()
    env.llm.app = "error"
    res = await _ask(env, "aggiungi un evento domani alle 10")
    assert "collegato" not in res.answer
    assert env.agent_calls == [] and len(env.rag_calls) == 1


@pytest.mark.asyncio
async def test_unreachable_apps_but_memory_question_is_answered_from_memory(env):
    class Down(FakeActionProvider):
        async def connected_toolkits(self, user_id):
            raise ActionProviderError("Composio request timed out")

    env.provider = Down()
    env.llm.app = False
    res = await _ask(env, _AGENDA)
    assert "couldn't reach" not in res.answer
    assert env.agent_calls == [] and len(env.rag_calls) == 1
    assert len(env.llm.app_checks) == 1


@pytest.mark.asyncio
async def test_unreachable_apps_check_without_a_named_app_lists_the_apps(env):
    class Down(FakeActionProvider):
        async def connected_toolkits(self, user_id):
            raise ActionProviderError("boom")

    env.provider = Down()
    res = await _ask(env, "Send a Slack message to the team")
    assert res.answer == "I couldn't reach your connected apps right now. Try again in a moment."
    env.provider = Down()
    res = await _ask(env, "crea una lista per il trasloco")
    assert res.answer.startswith("Non riesco a raggiungere")
    assert "Gmail" in env.llm.app_checks[-1][0].content


# --- G3: retry safety of client_request_id -----------------------------------------------

_UNFINISHED_IT = (
    "Non sono riuscito a completare la richiesta. Alcuni passaggi potrebbero essere stati "
    "eseguiti: controlla Impostazioni → Automazioni → Attività prima di riprovare."
)
_UNFINISHED_EN = (
    "I couldn't finish this request. Some steps may have run — check Settings → "
    "Automations → Activity before asking again."
)


def _record_response_writes(env):
    original = env.redis.set

    async def set_(key, value, ex=None, nx=False):
        if key.startswith("query:req:") and value != "processing":
            env.db.events.append("cache")
        return await original(key, value, ex=ex, nx=nx)

    env.redis.set = set_


@pytest.mark.asyncio
@pytest.mark.parametrize("question", ["riassumimi le ultime mail", "Cosa mi ha detto Marco ieri?"])
async def test_request_id_commits_before_caching_the_response(env, question):
    _record_response_writes(env)
    await _ask(env, question, request_id="r-10")
    assert env.db.events == ["commit", "cache"]


@pytest.mark.asyncio
async def test_without_request_id_the_commit_is_left_to_get_db(env):
    await _ask(env, "riassumimi le ultime mail")
    assert env.db.commits == 0


@pytest.mark.asyncio
async def test_commit_failure_deletes_the_marker_on_the_memory_path(env):
    env.db.commit_error = RuntimeError("db down")
    with pytest.raises(RuntimeError):
        await _ask(env, "Cosa mi ha detto Marco ieri?", request_id="r-11")
    assert f"query:req:{USER_ID}:r-11" not in env.redis.store


@pytest.mark.asyncio
async def test_commit_failure_after_the_agent_keeps_the_marker(env):
    env.db.commit_error = RuntimeError("db down")
    with pytest.raises(RuntimeError):
        await _ask(env, "riassumimi le ultime mail", request_id="r-12")
    env.db.commit_error = None
    again = await _ask(env, "riassumimi le ultime mail", request_id="r-12")
    assert again.answer == _UNFINISHED_IT
    assert len(env.agent_calls) == 1


@pytest.mark.asyncio
async def test_agent_failure_stores_couldnt_finish_and_never_reruns_the_agent(env, monkeypatch):
    calls = []

    async def broken_agent(*a, **kw):
        calls.append(a)
        raise RuntimeError("llm down after a tool ran")

    monkeypatch.setattr(q, "run_action_agent", broken_agent)
    sid = str(uuid.uuid4())
    with pytest.raises(RuntimeError):
        await _ask(env, "riassumimi le ultime mail", session_id=sid, request_id="r-13")
    key = f"query:req:{USER_ID}:r-13"
    assert key in env.redis.store and env.redis.ttl[key] == 600

    again = await _ask(env, "riassumimi le ultime mail", session_id=sid, request_id="r-13")
    assert again.answer == _UNFINISHED_IT
    assert again.sources == [] and again.pending_action is None
    assert again.session_id == sid
    assert len(calls) == 1  # the agent did not run a second time


@pytest.mark.asyncio
async def test_agent_failure_answer_is_in_the_question_language(env, monkeypatch):
    async def broken_agent(*a, **kw):
        raise RuntimeError("boom")

    monkeypatch.setattr(q, "run_action_agent", broken_agent)
    env.provider = FakeActionProvider(connected={"slack"})
    with pytest.raises(RuntimeError):
        await _ask(env, "Send a Slack message to the team", request_id="r-14")
    again = await _ask(env, "Send a Slack message to the team", request_id="r-14")
    assert again.answer == _UNFINISHED_EN


# --- Fix round 1: executed tools stay audited when the chat agent fails -----------------


def _agent_that_runs_a_tool_then_fails(env):
    from app.actions.audit import log_action
    from app.actions.provider import ToolResult

    async def agent(db, user_id, request, history, **kw):
        env.agent_calls.append((request, kw))
        await log_action(
            db, user_id, "chat", "TODOIST_CREATE_TASK", {"content": "milk"}, ToolResult(ok=True)
        )
        raise RuntimeError("llm down after the tool ran")

    return agent


def _committed_logs(env):
    from app.models.action_log import ActionLog

    return [o for o in getattr(env.db, "committed", []) if isinstance(o, ActionLog)]


@pytest.mark.asyncio
async def test_agent_failure_after_a_tool_commits_its_audit_row(env, monkeypatch):
    monkeypatch.setattr(q, "run_action_agent", _agent_that_runs_a_tool_then_fails(env))
    with pytest.raises(RuntimeError):
        await _ask(env, "riassumimi le ultime mail", request_id="r-20")

    (log,) = _committed_logs(env)
    assert log.tool == "TODOIST_CREATE_TASK" and log.outcome == "ok"
    assert log.source == "chat" and log.user_id == USER_ID
    assert env.db.events[:2] == ["rollback", "commit"]  # rolled back, row added again
    again = await _ask(env, "riassumimi le ultime mail", request_id="r-20")
    assert again.answer == _UNFINISHED_IT
    assert len(env.agent_calls) == 1


@pytest.mark.asyncio
async def test_agent_failure_without_request_id_also_keeps_the_audit_row(env, monkeypatch):
    monkeypatch.setattr(q, "run_action_agent", _agent_that_runs_a_tool_then_fails(env))
    with pytest.raises(RuntimeError):
        await _ask(env, "riassumimi le ultime mail")
    assert [log.tool for log in _committed_logs(env)] == ["TODOIST_CREATE_TASK"]


@pytest.mark.asyncio
async def test_agent_failure_without_executed_tools_commits_nothing(env, monkeypatch):
    async def broken_agent(*a, **kw):
        raise RuntimeError("boom")

    monkeypatch.setattr(q, "run_action_agent", broken_agent)
    with pytest.raises(RuntimeError):
        await _ask(env, "riassumimi le ultime mail", request_id="r-21")
    assert env.db.commits == 0
