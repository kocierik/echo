"""Unit tests: "Echo, ..." voice requests (wake detection, command window, voice worker)."""

import asyncio
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from app.actions import voice
from app.actions.agent import AgentOutcome
from app.actions.provider import ActionProviderError
from app.models.chat_session import ChatSession
from app.models.segment import Segment
from app.workers import main as worker_main
from app.workers import voice_requests as vr
from tests.fakes.action_provider import FakeActionProvider
from tests.mocks import MockLLMService

USER_ID = uuid.UUID("a0000000-0000-0000-0000-000000000001")
OTHER_USER = uuid.UUID("a0000000-0000-0000-0000-000000000002")
T0 = datetime(2026, 10, 13, 9, 0, 0, tzinfo=timezone.utc)


def _command(text):
    idx = voice.find_wake(text)
    return None if idx is None else text[idx:]


# --- find_wake ------------------------------------------------------------------------


def test_find_wake_returns_the_command_after_the_name():
    assert _command("Echo, segnami il dentista") == "segnami il dentista"
    assert _command("ehi eco riassumimi le mail") == "riassumimi le mail"
    assert _command("Hey Echo: what's on my calendar today?") == "what's on my calendar today?"
    assert _command("hey eco, fammi un riassunto") == "fammi un riassunto"
    assert _command("ECO! segna la spesa") == "segna la spesa"
    assert _command("Ok. Echo, segnami X") == "segnami X"


def test_find_wake_ignores_the_speaker_tag():
    assert _command("[You] Echo, segnami il dentista") == "segnami il dentista"
    assert _command("[Others] ehi eco riassumimi le mail") == "riassumimi le mail"
    assert _command("[Tu] Ok, Echo: manda un messaggio") == "manda un messaggio"
    assert _command("[Altri] Eco, che ore sono") == "che ore sono"
    # The tag is not counted as a word
    assert _command("[You] uno due tre Echo, fai X") == "fai X"


def test_find_wake_rejects_words_that_only_contain_the_name():
    """Review Focus 3, first layer."""
    assert voice.find_wake("ecografia domani") is None
    assert voice.find_wake("[You] ecografia domani alle dieci") is None
    assert voice.find_wake("l'eco della stanza") is None
    assert voice.find_wake("[Others] l’eco della stanza era forte") is None
    assert voice.find_wake("ho comprato un Echo") is None
    assert voice.find_wake("[You] ho comprato un Echo.") is None
    assert voice.find_wake("nessuna parola chiave qui") is None
    assert voice.find_wake("") is None


def test_find_wake_only_near_the_start():
    assert _command("uno due tre Echo, fai X") == "fai X"
    assert voice.find_wake("uno due tre quattro Echo, fai X") is None
    assert voice.find_wake("uno due tre quattro cinque Echo fai X") is None
    assert voice.find_wake("ieri sera abbiamo parlato a lungo di Echo e del progetto") is None


def test_find_wake_bare_name_waits_for_following_segments():
    # Addressed by name with the command in the next segment
    assert _command("Echo.") == ""
    assert _command("[You] Hey Echo") == ""
    assert _command("Ok Echo,") == ""
    # ...but a trailing noun is not an address
    assert voice.find_wake("ho comprato un Echo") is None


# --- text_before_wake -----------------------------------------------------------------


def test_text_before_wake_drops_the_command():
    assert voice.text_before_wake("Ok. Echo, segnami X") == "Ok."
    assert voice.text_before_wake("[You] Ok. Echo, segnami X") == "[You] Ok."
    assert voice.text_before_wake("Allora, ehi eco riassumimi le mail") == "Allora"
    assert voice.text_before_wake("Echo, segnami il dentista") == ""
    assert voice.text_before_wake("[You] Echo, segnami il dentista") == ""


def test_text_before_wake_keeps_text_without_a_wake():
    assert voice.text_before_wake("ho comprato un Echo") == "ho comprato un Echo"
    assert voice.text_before_wake("[You] l'eco della stanza") == "[You] l'eco della stanza"
    assert voice.text_before_wake("") == ""


# --- is_assistant_request -------------------------------------------------------------


class _JsonLLM(MockLLMService):
    def __init__(self, reply):
        super().__init__()
        self.reply = reply

    async def complete_json(self, messages, temperature=0.1):
        self.call_log.append(messages)
        if isinstance(self.reply, Exception):
            raise self.reply
        return self.reply


@pytest.mark.asyncio
async def test_is_assistant_request_reads_the_json_answer():
    llm = _JsonLLM({"assistant_request": True})
    assert await voice.is_assistant_request(llm, "Echo, segnami il dentista") is True
    user_msg = llm.call_log[0][-1]
    assert user_msg.role == "user" and "segnami il dentista" in user_msg.content

    assert await voice.is_assistant_request(
        _JsonLLM({"assistant_request": False}), "ho comprato un Echo nuovo"
    ) is False


@pytest.mark.asyncio
async def test_is_assistant_request_errors_mean_no_request():
    assert await voice.is_assistant_request(_JsonLLM(RuntimeError("down")), "Echo, x") is False
    assert await voice.is_assistant_request(_JsonLLM({"assistant_request": "yes"}), "x") is False
    assert await voice.is_assistant_request(_JsonLLM({}), "Echo, x") is False
    assert await voice.is_assistant_request(_JsonLLM(["nope"]), "Echo, x") is False


# --- collect_command ------------------------------------------------------------------


def _seg(
    text,
    offset_s=0.0,
    *,
    silence=0,
    status="completed",
    user_id=USER_ID,
    conversation_id=None,
    received_delay_s=1.0,
    duration_ms=5000,
):
    recorded = T0 + timedelta(seconds=offset_s)
    return SimpleNamespace(
        id=uuid.uuid4(),
        user_id=user_id,
        recorded_at=recorded,
        received_at=recorded + timedelta(milliseconds=duration_ms, seconds=received_delay_s),
        duration_ms=duration_ms,
        silence_before_ms=silence,
        transcription_status=status,
        conversation_id=conversation_id,
        transcription=(
            SimpleNamespace(id=uuid.uuid4(), text=text) if status == "completed" else None
        ),
    )


class _Result:
    def __init__(self, rows):
        self.rows = rows

    def scalars(self):
        return self

    def all(self):
        return list(self.rows)

    def first(self):
        return self.rows[0] if self.rows else None

    def scalar_one_or_none(self):
        return self.rows[0] if self.rows else None


class _Db:
    """Fake async session: answers Segment and ChatSession selects from in-memory rows."""

    def __init__(self, segments=(), sessions=()):
        self.segments = list(segments)
        self.sessions = list(sessions)
        self.added = []
        self.commits = 0
        self.rollbacks = 0
        self.queries = []

    async def execute(self, query):
        self.queries.append(query)
        entity = query.column_descriptions[0]["entity"]
        if entity is Segment:
            return _Result(self.segments)
        if entity is ChatSession:
            return _Result(self.sessions)
        raise AssertionError(f"unexpected query on {entity}")

    async def get(self, model, ident):
        if model is Segment:
            return next((s for s in self.segments if s.id == ident), None)
        return None

    def add(self, obj):
        self.added.append(obj)
        if isinstance(obj, ChatSession):
            self.sessions.append(obj)

    async def flush(self):
        pass

    async def commit(self):
        self.commits += 1

    async def rollback(self):
        self.rollbacks += 1


def _after(seg, seconds):
    return seg.received_at + timedelta(seconds=seconds)


@pytest.mark.asyncio
async def test_collect_command_joins_segments_until_a_pause():
    wake = _seg("[You] Echo, riassumimi")
    segs = [
        wake,
        _seg("[You] le ultime mail", 5.2, silence=200),
        _seg("[You] di Marco", 10.4, silence=2999),
        _seg("[You] e poi parliamo d'altro", 13.0, silence=3000),
        _seg("[You] ancora altro", 14.0, silence=0),
    ]
    db = _Db(segments=segs)
    command = await voice.collect_command(db, wake, _after(wake, 30))
    assert command == "riassumimi le ultime mail di Marco"


@pytest.mark.asyncio
async def test_collect_command_stops_fifteen_seconds_after_the_wake_start():
    wake = _seg("Echo, segnami")
    segs = [
        wake,
        _seg("il dentista", 5.0),
        _seg("martedì", 10.0),
        _seg("alle dieci", 14.9),
        _seg("questo è fuori finestra", 15.0),
    ]
    command = await voice.collect_command(_Db(segments=segs), wake, _after(wake, 30))
    assert command == "segnami il dentista martedì alle dieci"


@pytest.mark.asyncio
async def test_collect_command_waits_while_stt_is_pending():
    wake = _seg("Echo, segnami")
    pending = _seg(None, 5.0, status="pending")
    closing = _seg("altro discorso", 12.0, silence=4000)
    db = _Db(segments=[wake, pending, closing])

    assert await voice.collect_command(db, wake, _after(wake, 3)) is None
    pending.transcription_status = "processing"
    assert await voice.collect_command(db, wake, _after(wake, 24.9)) is None

    pending.transcription_status = "completed"
    pending.transcription = SimpleNamespace(id=uuid.uuid4(), text="[You] il dentista")
    assert await voice.collect_command(db, wake, _after(wake, 5)) == "segnami il dentista"


@pytest.mark.asyncio
async def test_collect_command_gives_up_waiting_after_25_seconds():
    wake = _seg("Echo, segnami il dentista")
    pending = _seg(None, 5.0, status="pending")
    late = _seg("martedì", 9.0)
    db = _Db(segments=[wake, pending, late])

    assert await voice.collect_command(db, wake, wake.received_at + timedelta(seconds=24)) is None
    # 25 s after arrival: answer with what is transcribed, stop at the stuck segment
    command = await voice.collect_command(db, wake, wake.received_at + timedelta(seconds=25))
    assert command == "segnami il dentista"


@pytest.mark.asyncio
async def test_collect_command_waits_briefly_for_a_continuation_still_uploading():
    wake = _seg("Echo, segnami il dentista")
    db = _Db(segments=[wake])
    # Nothing has closed the command yet: a continuation may still be on its way
    assert await voice.collect_command(db, wake, _after(wake, 1)) is None
    assert (
        await voice.collect_command(db, wake, _after(wake, voice.CONTINUATION_WAIT_S))
        == "segnami il dentista"
    )
    # A following pause closes the command at once
    db.segments.append(_seg("altro", 8.0, silence=3500))
    assert await voice.collect_command(db, wake, _after(wake, 1)) == "segnami il dentista"


@pytest.mark.asyncio
async def test_collect_command_ignores_other_users_and_conversations():
    conv = uuid.uuid4()
    wake = _seg("Echo, segnami", conversation_id=conv)
    segs = [
        wake,
        _seg("cose di un altro utente", 2.0, user_id=OTHER_USER),
        _seg("altra conversazione", 3.0, conversation_id=uuid.uuid4()),
        _seg("il dentista", 5.0, conversation_id=conv),
        _seg("martedì", 9.0),  # not grouped yet
        _seg("prima della sveglia", -3.0),
    ]
    command = await voice.collect_command(_Db(segments=segs), wake, _after(wake, 30))
    assert command == "segnami il dentista martedì"


@pytest.mark.asyncio
async def test_collect_command_orders_by_recording_time_and_skips_failed_stt():
    wake = _seg("Echo, segnami")
    segs = [
        _seg("martedì", 9.0),
        _seg(None, 7.0, status="failed"),
        wake,
        _seg("il dentista", 5.0),
    ]
    command = await voice.collect_command(_Db(segments=segs), wake, _after(wake, 30))
    assert command == "segnami il dentista martedì"


@pytest.mark.asyncio
async def test_collect_command_stops_at_a_new_request():
    wake = _seg("Echo, segnami il dentista")
    segs = [wake, _seg("Echo, riassumimi le mail", 5.0)]
    command = await voice.collect_command(_Db(segments=segs), wake, _after(wake, 30))
    assert command == "segnami il dentista"


@pytest.mark.asyncio
async def test_collect_command_with_bare_name_uses_the_next_segment():
    wake = _seg("[You] Hey Echo")
    segs = [wake, _seg("[You] riassumimi le mail", 3.0, silence=500)]
    command = await voice.collect_command(_Db(segments=segs), wake, _after(wake, 30))
    assert command == "riassumimi le mail"


# --- get_or_create_voice_session ------------------------------------------------------


@pytest.mark.asyncio
async def test_get_or_create_voice_session_creates_one():
    db = _Db()
    session = await voice.get_or_create_voice_session(db, USER_ID)
    assert session.title == "Voice requests"
    assert session.kind == "voice"
    assert session.user_id == USER_ID
    assert session.messages == []
    assert isinstance(session.id, uuid.UUID)
    assert db.added == [session]


@pytest.mark.asyncio
async def test_get_or_create_voice_session_reuses_the_existing_one():
    existing = ChatSession(
        id=uuid.uuid4(), user_id=USER_ID, title="Voice requests", kind="voice", messages=[]
    )
    db = _Db(sessions=[existing])
    assert await voice.get_or_create_voice_session(db, USER_ID) is existing
    assert db.added == []


# --- voice worker ---------------------------------------------------------------------


class _Redis:
    def __init__(self, items=()):
        self.lists = {vr.VOICE_QUEUE: list(items)}
        self.keys = {}
        self.set_calls = []

    async def lpush(self, name, *values):
        for value in values:
            self.lists.setdefault(name, []).insert(0, value)
        return len(self.lists[name])

    async def rpush(self, name, *values):
        self.lists.setdefault(name, []).extend(values)
        return len(self.lists[name])

    async def rpop(self, name):
        items = self.lists.get(name) or []
        return items.pop() if items else None

    async def llen(self, name):
        return len(self.lists.get(name) or [])

    async def set(self, key, value, nx=False, ex=None):
        self.set_calls.append((key, value, nx, ex))
        if nx and key in self.keys:
            return None
        self.keys[key] = value
        return True

    async def delete(self, *keys):
        for key in keys:
            self.keys.pop(key, None)


class _AnswerLLM(MockLLMService):
    """Cheap LLM (assistant check) and query LLM (RAG answer) in one fake."""

    def __init__(self, is_request=True, answer="Risposta dalla memoria"):
        super().__init__(default_response=answer)
        self.is_request = is_request
        self.json_calls = 0

    async def complete_json(self, messages, temperature=0.1):
        self.json_calls += 1
        self.call_log.append(messages)
        return {"assistant_request": self.is_request}


@pytest.fixture
def worker(monkeypatch):
    env = SimpleNamespace(
        db=_Db(),
        llm=_AnswerLLM(),
        provider=FakeActionProvider(connected={"gmail"}),
        provider_error=None,
        agent_calls=[],
        rag_calls=[],
        rag_context="Marco ha detto di chiamarlo domani.",
        outcome=AgentOutcome(answer="Hai 2 mail nuove da Marco."),
        agent_error=None,
        now=None,
        sessions_opened=0,
    )

    class _Factory:
        async def __aenter__(self):
            env.sessions_opened += 1
            return env.db

        async def __aexit__(self, *exc):
            return False

    def provider():
        if env.provider_error is not None:
            raise env.provider_error
        return env.provider

    async def fake_agent(db, user_id, request, history, **kw):
        env.agent_calls.append(SimpleNamespace(
            db=db, user_id=user_id, request=request, history=history, kw=kw,
        ))
        if env.agent_error is not None:
            raise env.agent_error
        return env.outcome

    async def fake_rag(db, user_id, question, **kw):
        env.rag_calls.append((user_id, question, kw))
        return SimpleNamespace(context=env.rag_context, sources=[], date_range=None)

    monkeypatch.setattr(vr, "async_session", lambda: _Factory())
    monkeypatch.setattr(vr, "get_action_provider", provider)
    monkeypatch.setattr(vr, "get_llm_query_service", lambda: env.llm)
    monkeypatch.setattr(vr, "get_llm_analysis_service", lambda: env.llm)
    monkeypatch.setattr(vr, "get_embedding_service", lambda: None)
    monkeypatch.setattr(vr, "run_action_agent", fake_agent)
    monkeypatch.setattr(vr, "retrieve_memory_context", fake_rag)
    monkeypatch.setattr(vr, "_utcnow", lambda: env.now)
    return env


def _ready(env, *segments):
    env.db.segments.extend(segments)
    env.now = max(s.received_at for s in segments) + timedelta(seconds=60)


def _voice_session(env):
    sessions = [s for s in env.db.sessions if s.kind == "voice"]
    assert len(sessions) == 1
    return sessions[0]


def _iso(value):
    ts = datetime.fromisoformat(value)
    assert ts.tzinfo is not None and ts.utcoffset() == timedelta(0)
    return ts


@pytest.mark.asyncio
async def test_worker_answers_with_the_agent_and_stores_both_messages(worker):
    wake = _seg("[You] Ok. Echo, riassumimi")
    _ready(worker, wake, _seg("[You] le ultime mail", 5.0))
    redis = _Redis()

    assert await vr.handle_voice_item(redis, str(wake.id)) is True

    call = worker.agent_calls[0]
    assert call.request == "riassumimi le ultime mail"
    assert call.user_id == USER_ID
    assert call.kw["source"] == "voice"
    assert call.kw["provider"] is worker.provider
    assert call.kw["llm"] is worker.llm
    session = _voice_session(worker)
    assert call.kw["session_id"] == session.id
    assert session.title == "Voice requests"

    user_msg, answer = session.messages
    assert user_msg["role"] == "user" and user_msg["content"] == "riassumimi le ultime mail"
    assert answer["role"] == "assistant" and answer["content"] == "Hai 2 mail nuove da Marco."
    assert answer["actions"] is True
    assert "pending_action" not in answer
    assert _iso(user_msg["timestamp"]) <= _iso(answer["timestamp"])
    assert worker.db.commits == 1
    # The cheap check saw the whole utterance, not only the command
    check_text = worker.llm.call_log[0][-1].content
    assert "Ok. Echo, riassumimi le ultime mail" in check_text
    assert worker.rag_calls == []


@pytest.mark.asyncio
async def test_worker_stores_the_pending_action_like_chat(worker):
    pending = SimpleNamespace(
        id=uuid.uuid4(), summary="GMAIL_SEND_EMAIL: to=ada@example.com", status="pending"
    )
    worker.outcome = AgentOutcome(answer="Conferma nell'app.", pending_action=pending)
    wake = _seg("Echo, scrivi ad Ada che arrivo tardi")
    _ready(worker, wake)

    await vr.handle_voice_item(_Redis(), str(wake.id))

    answer = _voice_session(worker).messages[-1]
    assert answer["pending_action"] == {
        "id": str(pending.id),
        "summary": "GMAIL_SEND_EMAIL: to=ada@example.com",
        "status": "pending",
    }
    assert answer["actions"] is True


@pytest.mark.asyncio
async def test_worker_appends_to_one_voice_session_with_recent_history(worker):
    first = _seg("Echo, riassumimi le mail")
    second = _seg("Echo, rispondi a Marco", 60.0)
    _ready(worker, first, second)
    redis = _Redis()

    await vr.handle_voice_item(redis, str(first.id))
    await vr.handle_voice_item(redis, str(second.id))

    session = _voice_session(worker)
    assert [m["role"] for m in session.messages] == ["user", "assistant"] * 2
    assert all("timestamp" in m for m in session.messages)
    assert worker.agent_calls[1].history == [
        {"role": "user", "content": "riassumimi le mail"},
        {"role": "assistant", "content": "Hai 2 mail nuove da Marco."},
    ]
    assert worker.db.commits == 2


@pytest.mark.asyncio
async def test_worker_falls_back_to_memory_without_connected_toolkits(worker):
    worker.provider = FakeActionProvider(connected=set())
    wake = _seg("Echo, cosa mi ha detto Marco ieri?")
    _ready(worker, wake)

    await vr.handle_voice_item(_Redis(), str(wake.id))

    assert worker.agent_calls == []
    assert worker.rag_calls[0][:2] == (USER_ID, "cosa mi ha detto Marco ieri?")
    answer = _voice_session(worker).messages[-1]
    assert answer["content"] == "Risposta dalla memoria"
    assert "actions" not in answer and "timestamp" in answer
    rag_prompt = worker.llm.call_log[-1]
    assert rag_prompt[0].role == "system"
    assert "Marco ha detto di chiamarlo domani." in rag_prompt[-1].content


@pytest.mark.asyncio
async def test_worker_falls_back_to_memory_when_composio_is_not_configured(worker):
    worker.provider_error = ActionProviderError("Composio is not configured")
    wake = _seg("Echo, riassumimi le mail")
    _ready(worker, wake)

    await vr.handle_voice_item(_Redis(), str(wake.id))

    assert worker.agent_calls == [] and len(worker.rag_calls) == 1
    assert _voice_session(worker).messages[-1]["content"] == "Risposta dalla memoria"


@pytest.mark.asyncio
async def test_worker_memory_fallback_without_results(worker):
    worker.provider = FakeActionProvider(connected=set())
    worker.rag_context = ""
    wake = _seg("Echo, cosa ho fatto ieri?")
    _ready(worker, wake)

    await vr.handle_voice_item(_Redis(), str(wake.id))

    answer = _voice_session(worker).messages[-1]
    assert answer["content"] == (
        "Non ho trovato informazioni nella memoria per il periodo indicato. "
        "Prova a riformulare la domanda o a estendere il periodo."
    )


@pytest.mark.asyncio
async def test_worker_ignores_a_mention_rejected_by_the_llm_check(worker):
    """Review Focus 3, second layer: find_wake hits, the cheap LLM says no."""
    worker.llm.is_request = False
    wake = _seg("[Others] ho comprato un Echo nuovo ieri")
    assert voice.find_wake(wake.transcription.text) is not None
    _ready(worker, wake)

    assert await vr.handle_voice_item(_Redis(), str(wake.id)) is True

    assert worker.llm.json_calls == 1
    assert worker.agent_calls == [] and worker.rag_calls == []
    assert worker.db.sessions == []
    assert worker.db.commits == 0


@pytest.mark.asyncio
async def test_worker_reports_not_ready_while_the_command_is_open(worker):
    wake = _seg("Echo, segnami")
    worker.db.segments.extend([wake, _seg(None, 5.0, status="pending")])
    worker.now = wake.received_at + timedelta(seconds=3)
    redis = _Redis()

    assert await vr.handle_voice_item(redis, str(wake.id)) is False
    assert worker.llm.json_calls == 0 and worker.agent_calls == []
    assert redis.keys == {}


@pytest.mark.asyncio
async def test_worker_processes_a_segment_only_once(worker):
    wake = _seg("Echo, riassumimi le mail")
    _ready(worker, wake)
    redis = _Redis()

    assert await vr.handle_voice_item(redis, str(wake.id)) is True
    assert await vr.handle_voice_item(redis, str(wake.id)) is True

    assert len(worker.agent_calls) == 1
    assert len(_voice_session(worker).messages) == 2
    key, _, nx, ex = redis.set_calls[0]
    assert key == f"voice:done:{wake.id}" and nx is True and ex > 0


@pytest.mark.asyncio
async def test_worker_drops_unknown_or_invalid_items(worker):
    worker.now = T0
    assert await vr.handle_voice_item(_Redis(), "not-a-uuid") is True
    assert await vr.handle_voice_item(_Redis(), str(uuid.uuid4())) is True
    assert worker.agent_calls == [] and worker.db.commits == 0


@pytest.mark.asyncio
async def test_queue_loop_requeues_waits_and_survives_errors(worker, monkeypatch):
    broken = _seg("Echo, riassumimi le mail")
    waiting = _seg("Echo, segnami", 100.0)
    good = _seg("Echo, cosa ho in agenda", 200.0)
    stuck_stt = _seg(None, 105.0, status="pending")
    worker.db.segments.extend([broken, waiting, stuck_stt, good])
    worker.now = good.received_at + timedelta(seconds=60)
    stuck_stt.recorded_at = waiting.recorded_at + timedelta(seconds=5)
    # The waiting item arrived "now": its following segment is still in STT
    waiting.received_at = worker.now - timedelta(seconds=2)

    calls = []

    async def fake_agent(db, user_id, request, history, **kw):
        calls.append(request)
        if request == "riassumimi le mail":
            raise RuntimeError("provider exploded")
        return AgentOutcome(answer="Domani hai il dentista.")

    monkeypatch.setattr(vr, "run_action_agent", fake_agent)

    shutdown = asyncio.Event()
    sleeps = []

    async def fake_sleep(seconds, event):
        sleeps.append(seconds)
        if len(sleeps) >= 2:
            event.set()
            return True
        return False

    monkeypatch.setattr(vr, "sleep_or_shutdown", fake_sleep)
    # lpush on enqueue -> the oldest item is popped first (rpop)
    redis = _Redis()
    for seg in (broken, waiting, good):
        await redis.lpush(vr.VOICE_QUEUE, str(seg.id).encode())

    await asyncio.wait_for(vr.process_voice_queue(redis, shutdown), timeout=2)

    assert calls == ["riassumimi le mail", "cosa ho in agenda"]
    assert sleeps == [vr.POLL_INTERVAL_S, vr.POLL_INTERVAL_S]
    assert vr.POLL_INTERVAL_S == 2
    # The waiting item is still queued for the next poll, nothing else is
    assert redis.lists[vr.VOICE_QUEUE] == [str(waiting.id).encode()]
    session = _voice_session(worker)
    assert [m["content"] for m in session.messages] == [
        "cosa ho in agenda", "Domani hai il dentista.",
    ]
    assert worker.db.rollbacks >= 1


@pytest.mark.asyncio
async def test_queue_loop_sleeps_when_empty_and_exits_on_shutdown(worker, monkeypatch):
    shutdown = asyncio.Event()

    async def fake_sleep(seconds, event):
        event.set()
        return True

    monkeypatch.setattr(vr, "sleep_or_shutdown", fake_sleep)
    await asyncio.wait_for(vr.process_voice_queue(_Redis(), shutdown), timeout=1)
    assert worker.sessions_opened == 0


# --- STT worker enqueues wake segments ------------------------------------------------


class _SttLoopRedis:
    def __init__(self, segment_id):
        self.items = [str(segment_id).encode()]
        self.pushes = []

    async def brpop(self, queue, timeout=0):
        if self.items:
            return queue, self.items.pop()
        worker_main.shutdown_event.set()
        return None

    async def lpush(self, queue, payload):
        self.pushes.append((queue, payload))


async def _run_stt(monkeypatch, text):
    segment_id = uuid.uuid4()
    segment = SimpleNamespace(
        id=segment_id, user_id=USER_ID, audio_energy=10, speaker=None,
        transcription_status="processing",
    )

    class _SttDb:
        def add(self, obj):
            pass

        async def commit(self):
            pass

    class _Factory:
        async def __aenter__(self):
            return _SttDb()

        async def __aexit__(self, *exc):
            return False

    async def claim(_db, _redis, _segment_id):
        return segment, b""

    async def prompt(_db, _user_id):
        return ""

    async def retry(func, *args, **kwargs):
        return SimpleNamespace(text=text, language="it", confidence=0.9)

    async def classify(_db, _user_id, _energy):
        return "self"

    monkeypatch.setattr(worker_main, "get_stt_service", lambda: SimpleNamespace(transcribe=None))
    monkeypatch.setattr(worker_main, "async_session", lambda: _Factory())
    monkeypatch.setattr(worker_main, "_claim_stt_audio", claim)
    monkeypatch.setattr(worker_main, "adpcm_to_wav", lambda data: data)
    monkeypatch.setattr(worker_main, "build_stt_prompt", prompt)
    monkeypatch.setattr(worker_main, "retry_with_backoff", retry)
    monkeypatch.setattr(worker_main, "classify_segment", classify)

    redis = _SttLoopRedis(segment_id)
    worker_main.shutdown_event.clear()
    try:
        await asyncio.wait_for(worker_main.process_stt(redis), timeout=2)
    finally:
        worker_main.shutdown_event.clear()
    return segment_id, redis.pushes


@pytest.mark.asyncio
async def test_stt_enqueues_segments_addressed_to_echo(monkeypatch):
    segment_id, pushes = await _run_stt(monkeypatch, "Echo, segnami il dentista")
    assert ("queue:analysis", str(segment_id)) in pushes
    assert ("queue:voice", str(segment_id)) in pushes


@pytest.mark.asyncio
async def test_stt_does_not_enqueue_plain_speech(monkeypatch):
    segment_id, pushes = await _run_stt(monkeypatch, "ho comprato un Echo")
    assert pushes == [("queue:analysis", str(segment_id))]


def test_worker_main_starts_the_voice_loop():
    import inspect

    source = inspect.getsource(worker_main.main)
    assert "process_voice_queue(redis_client, shutdown_event)" in source
    assert 'name="voice_worker"' in source
