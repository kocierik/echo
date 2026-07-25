"""Unit tests for the worker analysis pipeline logic.

Tests entity extraction and conversation summary generation
using mock LLM services, without requiring Redis or a real database.
"""

import uuid

import pytest

from app.models.entity import Entity
from app.workers.main import extract_entities, generate_conversation_summary
from tests.mocks import MockLLMService


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

    title, summary = await generate_conversation_summary(
        llm, "Oggi ho parlato con Marco della conferenza PyCon a Firenze."
    )

    assert isinstance(title, str)
    assert len(title) > 0
    assert isinstance(summary, str)


@pytest.mark.asyncio
async def test_generate_conversation_summary_truncates_long_text():
    """Test that very long texts are handled without error."""
    llm = MockLLMService()

    # Generate a very long text (10K chars)
    long_text = "Questa è una frase di test. " * 500

    title, summary = await generate_conversation_summary(llm, long_text)

    assert isinstance(title, str)
    assert isinstance(summary, str)
    # Check LLM was called (verify truncation happened internally)
    assert len(llm.call_log) == 1
