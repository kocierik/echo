"""Memory retrieval: embedding -> context string + sources, no LLM."""

import uuid
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest

from app.services.memory_retrieval import MemoryContext, retrieve_memory_context


class _Result:
    def __init__(self, rows):
        self._rows = rows

    def all(self):
        return self._rows


class _FakeDB:
    """Returns queued results: chunk search first, then summaries."""

    def __init__(self, *results):
        self._results = list(results)

    async def execute(self, _query):
        return _Result(self._results.pop(0))


class _FakeEmbedding:
    async def embed(self, _text):
        return [0.1, 0.2, 0.3]


def _chunk_row():
    return SimpleNamespace(
        id=uuid.uuid4(),
        conversation_id=uuid.uuid4(),
        text="We agreed to ship the demo on Friday.",
        similarity=0.87654321,
        conversation_title="Planning",
        conversation_started_at=datetime(2026, 10, 1, 9, 30, tzinfo=timezone.utc),
    )


@pytest.mark.asyncio
async def test_context_has_summary_entities_chunk_and_sources():
    row = _chunk_row()
    summary = SimpleNamespace(
        title="Planning",
        summary="Planned the demo.",
        started_at=datetime(2026, 10, 1, 9, 30, tzinfo=timezone.utc),
    )
    db = _FakeDB([row], [summary])
    with (
        patch(
            "app.routers.feedback.get_chunk_feedback_scores",
            AsyncMock(return_value={}),
        ),
        patch(
            "app.services.memory_retrieval.people_named_in",
            AsyncMock(return_value=[]),
        ),
        patch(
            "app.services.memory_retrieval.find_relevant_entities",
            AsyncMock(return_value="- [TASK] Ship demo"),
        ),
    ):
        mc = await retrieve_memory_context(
            db, uuid.uuid4(), "when is the demo?", embedding_service=_FakeEmbedding()
        )

    assert isinstance(mc, MemoryContext)
    assert "Relevant conversation summaries:\n- [01/10/2026 09:30] Planning: Planned the demo." in (
        mc.context
    )
    assert "Structured knowledge:\n- [TASK] Ship demo" in mc.context
    assert row.text in mc.context
    assert "\n\n---\n\n" in mc.context
    assert mc.sources == [
        {
            "conversation_id": row.conversation_id,
            "chunk_id": row.id,
            "text": row.text[:200],
            "similarity": 0.8765,
            "title": "Planning",
            "started_at": datetime(2026, 10, 1, 9, 30, tzinfo=timezone.utc),
        }
    ]


@pytest.mark.asyncio
async def test_empty_memory_gives_empty_context():
    db = _FakeDB([])
    with (
        patch(
            "app.services.memory_retrieval.people_named_in",
            AsyncMock(return_value=[]),
        ),
        patch(
            "app.services.memory_retrieval.find_relevant_entities",
            AsyncMock(return_value=""),
        ),
    ):
        mc = await retrieve_memory_context(
            db, uuid.uuid4(), "anything?", embedding_service=_FakeEmbedding()
        )
    assert mc.context == ""
    assert mc.sources == []
    assert mc.date_range is None
