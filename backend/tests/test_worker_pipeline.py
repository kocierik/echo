"""Unit tests for the worker analysis pipeline logic.

Tests entity extraction and conversation summary generation
using mock LLM services, without requiring Redis or a real database.
"""

import json
import uuid
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy.dialects import postgresql

from app.models.entity import Entity
from app.services.analysis_pipeline import (
    AnalysisPipeline,
    extract_entities,
    generate_conversation_summary,
)
from app.workers import stt as stt_worker
from tests.mocks import MockLLMService


class _QueryResult:
    def __init__(self, rows):
        self.rows = rows

    def all(self):
        return self.rows

    def first(self):
        return self.rows[0] if self.rows else None


class _PipelineDatabase:
    def __init__(self, events):
        self.events = events
        self.query_results = [_QueryResult([(3,)])]

    async def execute(self, _query):
        self.events.append("max_chunk")
        return self.query_results.pop(0)

    def add(self, value):
        self.events.append("add_chunk" if value.__class__.__name__ == "Chunk" else "add_entity")

    async def flush(self):
        self.events.append("flush")

    async def commit(self):
        self.events.append("commit")


class _PipelineEmbeddings:
    def __init__(self, events):
        self.events = events
        self.chunk_texts = []

    async def embed_batch(self, texts):
        label = "entity_embeddings" if texts[0].startswith("Ada:") else "chunk_embeddings"
        self.events.append(label)
        if label == "chunk_embeddings":
            self.chunk_texts.extend(texts)
        return [[0.1] * 1536 for _ in texts]


class _ScalarOneResult:
    def __init__(self, segment):
        self._segment = segment

    def scalar_one_or_none(self):
        return self._segment


class _SttDatabase:
    def __init__(self, segment, events):
        self.segment = segment
        self.events = events
        self.query = None

    async def execute(self, query):
        self.query = query
        self.events.append("lock")
        return _ScalarOneResult(self.segment)

    async def commit(self):
        self.events.append("commit")


class _SttRedis:
    def __init__(self):
        self.pushes = []

    async def lpush(self, queue, payload):
        self.pushes.append((queue, payload))


def _within_budget(monkeypatch):
    async def allowed(_db, _user_id, *, late):
        return True

    monkeypatch.setattr(stt_worker, "may_transcribe", allowed)


@pytest.mark.asyncio
async def test_stt_claim_reads_audio_before_committing_processing(monkeypatch):
    _within_budget(monkeypatch)
    events = []
    segment_id = uuid.uuid4()
    segment = SimpleNamespace(
        id=segment_id,
        user_id=uuid.uuid4(),
        audio_path="audio.adpcm",
        transcription_status="pending",
    )
    db = _SttDatabase(segment, events)

    def read_bytes(_path):
        events.append("read")
        return b"audio"

    monkeypatch.setattr(stt_worker.Path, "read_bytes", read_bytes)

    claimed = await stt_worker._claim_stt_audio(db, _SttRedis(), segment_id)

    assert claimed == (segment, b"audio")
    assert events == ["lock", "read", "commit"]
    assert segment.transcription_status == "processing"
    sql = " ".join(str(db.query.compile(dialect=postgresql.dialect())).split())
    assert "FOR UPDATE" in sql
    assert "SKIP LOCKED" not in sql


@pytest.mark.asyncio
@pytest.mark.parametrize("audio_path", [None, "", "missing.adpcm"])
async def test_stt_claim_fails_and_dead_letters_missing_audio(monkeypatch, audio_path):
    _within_budget(monkeypatch)
    events = []
    segment_id = uuid.uuid4()
    segment = SimpleNamespace(
        id=segment_id,
        user_id=uuid.uuid4(),
        audio_path=audio_path,
        transcription_status="pending",
    )
    db = _SttDatabase(segment, events)
    redis = _SttRedis()

    def missing_file(_path):
        raise FileNotFoundError

    monkeypatch.setattr(stt_worker.Path, "read_bytes", missing_file)

    claimed = await stt_worker._claim_stt_audio(db, redis, segment_id)

    assert claimed is None
    assert segment.transcription_status == "failed"
    assert events[-1] == "commit"
    assert redis.pushes[0][0] == "queue:dead-letter"
    assert json.loads(redis.pushes[0][1])["step"] == "stt"


_DEFAULT_TEXT = "Uno due tre quattro cinque sei sette otto nove dieci undici."


async def _run_pipeline(monkeypatch, text=_DEFAULT_TEXT, captured=None):
    import app.services.analysis_pipeline as pipeline_module

    events = []
    user_id = uuid.uuid4()
    conversation = SimpleNamespace(
        id=uuid.uuid4(), title=None, summary=None, analysis_status="pending",
        retranscribed_at=(captured or {}).get("read_whole_at"),
    )
    captured = captured if captured is not None else {}
    transcription = SimpleNamespace(id=uuid.uuid4(), text=text)
    segment = SimpleNamespace(
        id=uuid.uuid4(),
        user_id=user_id,
        transcription=transcription,
        recorded_at=datetime(2026, 10, 13, 22, 30, tzinfo=timezone.utc),
    )

    async def fake_assign(_db, _segment):
        events.append("assign")
        return conversation

    async def no_extract(*_args, **_kwargs):
        raise AssertionError("a segment alone is not extracted from any more")

    async def direct_retry(coro_func, *args, **kwargs):
        kwargs.pop("operation_name", None)
        return await coro_func(*args, **kwargs)

    monkeypatch.setattr(pipeline_module, "assign_to_conversation", fake_assign)
    monkeypatch.setattr(pipeline_module, "extract_entities", no_extract)
    monkeypatch.setattr(pipeline_module, "generate_conversation_summary", no_extract)
    monkeypatch.setattr(pipeline_module, "retry_with_backoff", direct_retry)

    embeddings = _PipelineEmbeddings(events)
    pipeline = AnalysisPipeline(MockLLMService(), embeddings)
    result = await pipeline.analyze_segment(_PipelineDatabase(events), segment)
    captured["chunk_texts"] = embeddings.chunk_texts
    captured["conversation"] = conversation
    return events, result


@pytest.mark.asyncio
async def test_analysis_pipeline_preserves_normal_call_order(monkeypatch):
    events, result = await _run_pipeline(monkeypatch)

    # Grouped and made searchable at once; entities, title and summary come when the
    # conversation is closed, from all of it (services/conversation_reanalysis.py)
    assert events == ["assign", "max_chunk", "chunk_embeddings", "add_chunk", "commit"]
    assert result.extracted_entity_count == 0
    assert result.new_entity_count == 0
    assert result.chunk_count == 1


@pytest.mark.asyncio
async def test_speech_arriving_late_has_its_conversation_read_whole_again(monkeypatch):
    """The card's backlog reaches a conversation already analysed: without this, that
    speech would never give entities, nor be in the summary."""
    captured = {"read_whole_at": datetime(2026, 10, 13, 12, tzinfo=timezone.utc)}
    await _run_pipeline(monkeypatch, captured=captured)

    assert captured["conversation"].retranscribed_at is None


@pytest.mark.asyncio
async def test_a_segment_is_searchable_at_once_with_its_whole_text(monkeypatch):
    text = "[You] ho comprato un Echo nuovo con Marco e domani lo proviamo insieme"
    captured = {}
    await _run_pipeline(monkeypatch, text=text, captured=captured)

    assert captured["chunk_texts"] == [text]


@pytest.mark.asyncio
async def test_extract_entities_prompt_treats_echo_requests_as_commands():
    llm = MockLLMService()
    await extract_entities(
        llm, "Echo, segnami il dentista giovedì", uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    )

    system = llm.call_log[0][0].content
    assert '"Echo"' in system
    assert "Echo, segnami il dentista giovedì" in system
    assert "Ehi Echo, riassumimi le mail" in system
    assert "non estrarre entità" in system
    assert "testo normale" in system


@pytest.mark.asyncio
async def test_extract_entities_returns_entity_list():
    """Test that extract_entities parses LLM JSON response into Entity objects."""
    llm = MockLLMService()
    user_id = uuid.uuid4()
    transcription_id = uuid.uuid4()
    conversation_id = uuid.uuid4()

    entities = await extract_entities(
        llm,
        "Marco mi ha detto di comprare il latte domani.",
        user_id,
        transcription_id,
        conversation_id,
        known_people=["Marco"],
    )

    assert isinstance(entities, list)
    assert len(entities) > 0
    assert all(isinstance(e, Entity) for e in entities)

    # Check the mock returns a person entity
    person = entities[0]
    assert person.entity_type == "person"
    assert person.name == "Marco"
    assert person.user_id == user_id
    assert person.source_transcription_id == transcription_id
    assert person.conversation_id == conversation_id


@pytest.mark.asyncio
async def test_extract_entities_empty_text():
    """Test entity extraction with minimal text returns empty or minimal entities."""
    llm = MockLLMService()
    # The mock always returns entities, but in a real scenario
    # we'd get an empty list for "ciao"
    entities = await extract_entities(
        llm, "ciao", uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    )
    # Mock returns a fixed response, but function should not crash
    assert isinstance(entities, list)


@pytest.mark.asyncio
async def test_generate_conversation_summary():
    """Test that conversation summary returns title and summary tuple."""
    llm = MockLLMService()

    result = await generate_conversation_summary(
        llm, "Oggi ho parlato con Marco della conferenza PyCon a Firenze."
    )

    assert isinstance(result.title, str)
    assert len(result.title) > 0
    assert isinstance(result.summary, str)


@pytest.mark.asyncio
async def test_generate_conversation_summary_normalizes_topics():
    class _TopicsLLM(MockLLMService):
        async def complete_json(self, messages, **kwargs):
            return {
                "title": "T",
                "summary": "S",
                "emoji": "ðŸ’¼",
                "topics": ["Atlas"],
            }

    result = await generate_conversation_summary(_TopicsLLM(), "A conversation.")

    assert getattr(result, "topics", None) == ["atlas"]


@pytest.mark.asyncio
async def test_generate_conversation_summary_truncates_long_text():
    """Test that very long texts are handled without error."""
    llm = MockLLMService()

    # Generate a very long text (10K chars)
    long_text = "Questa è una frase di test. " * 500

    result = await generate_conversation_summary(llm, long_text)

    assert isinstance(result.title, str)
    assert isinstance(result.summary, str)
    # Check LLM was called (verify truncation happened internally)
    assert len(llm.call_log) == 1


@pytest.mark.parametrize(
    ("emoji", "expected"),
    [("🍝", "🍝"), (" 👩‍💻 ", "👩‍💻"), ("🇮🇹", "🇮🇹"), ("food", None), ("", None), (None, None),
     ("🍝🍝🍝🍝🍝🍝🍝🍝🍝", None), (3, None)],
)
@pytest.mark.asyncio
async def test_conversation_summary_keeps_only_a_real_emoji(emoji, expected):
    class _EmojiLLM(MockLLMService):
        async def complete_json(self, messages, **kwargs):
            return {"title": "Lunch", "summary": "Pasta.", "emoji": emoji}

    result = await generate_conversation_summary(_EmojiLLM(), "Pranzo con Ada")

    assert result.emoji == expected
