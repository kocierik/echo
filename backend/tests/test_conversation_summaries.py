"""Unit tests: titles/summaries are generated only for closed conversations."""

import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy.dialects import postgresql

from app.services import conversation_close
from app.workers import summaries
from app.workers.retry import RetryExhaustedError

NOW = datetime(2026, 10, 13, 12, 0, tzinfo=timezone.utc)


class _Rows:
    def __init__(self, rows):
        self.rows = rows

    def all(self):
        return self.rows

    def scalars(self):
        return self

    def __iter__(self):
        return iter(self.rows)


class _FakeSession:
    def __init__(self, conversations, texts_by_conversation):
        self.conversations = conversations
        self.texts = texts_by_conversation
        self.queries = []
        self.committed = False

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_exc):
        return False

    async def execute(self, query):
        self.queries.append(query)
        if len(self.queries) == 1:
            return _Rows(self.conversations)
        if "entity_mentions" in str(query):
            return _Rows([])  # the conversation's people, kept out of its topics
        if "FROM photos" in str(query):
            return _Rows([])  # no photo taken during it
        texts_asked = sum("transcriptions" in str(q) for q in self.queries)
        conversation = self.conversations[texts_asked - 1]
        return _Rows([(NOW, text) for text in self.texts[conversation.id]])

    async def commit(self):
        self.committed = True


class _FakeLLM:
    def __init__(self):
        self.calls = 0

    async def complete_json(self, _messages):
        self.calls += 1
        return {
            "title": "Pranzo con Ada",
            "summary": "Ada propone il progetto Atlas.",
            "emoji": "🍝",
        }


def _conversation():
    return SimpleNamespace(
        id=uuid.uuid4(), user_id=uuid.uuid4(), title=None, summary=None, emoji=None
    )


def _patch_direct_retry(monkeypatch):
    async def direct_retry(coro_func, *args, **kwargs):
        kwargs.pop("operation_name", None)
        return await coro_func(*args, **kwargs)

    monkeypatch.setattr(conversation_close, "retry_with_backoff", direct_retry)


@pytest.mark.asyncio
async def test_long_closed_conversation_gets_title_and_summary(monkeypatch):
    _patch_direct_retry(monkeypatch)
    conversation = _conversation()
    session = _FakeSession(
        [conversation],
        {
            conversation.id: [
                "[Tu] Domani pranzo con Ada.",
                "Parliamo del progetto Atlas e dei tempi di consegna.",
            ]
        },
    )
    llm = _FakeLLM()

    count = await summaries.summarize_closed_conversations(
        now=NOW, session_factory=lambda: session, llm_service=llm
    )

    assert count == 1
    assert conversation.title == "Pranzo con Ada"
    assert conversation.summary == "Ada propone il progetto Atlas."
    assert conversation.emoji == "🍝"
    assert session.committed


@pytest.mark.asyncio
async def test_short_conversation_is_marked_without_calling_the_llm(monkeypatch):
    _patch_direct_retry(monkeypatch)
    conversation = _conversation()
    session = _FakeSession([conversation], {conversation.id: ["Ok, a dopo."]})
    llm = _FakeLLM()

    count = await summaries.summarize_closed_conversations(
        now=NOW, session_factory=lambda: session, llm_service=llm
    )

    assert count == 0
    assert llm.calls == 0
    assert conversation.summary == ""
    assert conversation.title is None


@pytest.mark.asyncio
async def test_llm_failure_leaves_the_conversation_for_the_next_run(monkeypatch):
    async def failing_retry(*_args, **_kwargs):
        raise RetryExhaustedError(RuntimeError("timeout"), 3)

    monkeypatch.setattr(conversation_close, "retry_with_backoff", failing_retry)
    conversation = _conversation()
    words = " ".join(f"parola{i}" for i in range(30))
    session = _FakeSession([conversation], {conversation.id: [words]})

    count = await summaries.summarize_closed_conversations(
        now=NOW, session_factory=lambda: session, llm_service=_FakeLLM()
    )

    assert count == 0
    assert conversation.summary is None


def test_query_selects_only_unsummarized_closed_completed_conversations():
    query = summaries._build_closed_conversations_query(NOW)
    compiled = query.compile(
        dialect=postgresql.dialect(), compile_kwargs={"literal_binds": True}
    )
    sql = " ".join(str(compiled).split())

    assert "conversations.summary IS NULL" in sql
    assert "conversations.analysis_status = 'completed'" in sql
    assert "coalesce(conversations.ended_at, conversations.started_at) <" in sql
    cutoff = NOW - timedelta(milliseconds=summaries.settings.silence_timeout_ms)
    assert cutoff.strftime("%Y-%m-%d %H:%M:%S") in sql
    # Transcribed again whole first (services/retranscription.py)
    assert "conversations.retranscribed_at IS NOT NULL" in sql
    assert "FOR UPDATE SKIP LOCKED" in sql


def test_query_requires_aware_now():
    with pytest.raises(ValueError):
        summaries._build_closed_conversations_query(datetime(2026, 10, 13))


@pytest.mark.asyncio
async def test_a_photo_taken_during_it_reaches_the_summary_where_it_was_taken(db_session):
    # A whiteboard photographed in a meeting: its text belongs in the meeting's summary
    from app.models.photo import Photo
    from tests.conftest import TEST_USER_ID
    from tests.factories import make_conversation

    start = datetime(2026, 11, 20, 10, 0, tzinfo=timezone.utc)
    conversation, _ = await make_conversation(db_session, started_at=start, texts=())
    db_session.add_all([
        Photo(
            user_id=TEST_USER_ID, source="voice", status="done",
            conversation_id=conversation.id, captured_at=start + timedelta(minutes=5),
            description="Lavagna: rilascio 2 dicembre, Sara fa il login",
        ),
        Photo(  # not analysed yet: nothing to add
            user_id=TEST_USER_ID, source="voice", status="received",
            conversation_id=conversation.id, captured_at=start + timedelta(minutes=6),
        ),
    ])
    await db_session.flush()

    text = await conversation_close.with_photos(
        db_session,
        conversation.id,
        [(start, "Allora, i tempi."), (start + timedelta(minutes=8), "Ok, ci siamo.")],
    )

    assert text == (
        "Allora, i tempi. [Photo the user took: Lavagna: rilascio 2 dicembre, Sara fa il "
        "login] Ok, ci siamo."
    )
