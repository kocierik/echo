"""A question naming a topic of several conversations gets that topic's story."""

from datetime import datetime, timedelta, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.services.memory_retrieval import retrieve_memory_context, topics_named_in
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation
from tests.mocks import MockEmbeddingService


async def _talk(db, days_ago: int, title: str, summary: str, topics: list[str]):
    conversation, _ = await make_conversation(
        db,
        started_at=datetime.now(timezone.utc) - timedelta(days=days_ago),
        title=title,
        summary=summary,
        texts=(),
    )
    conversation.topics = topics
    return conversation


async def test_a_topic_of_several_conversations_tells_its_story_latest_first(
    db_session: AsyncSession,
):
    await _talk(db_session, 60, "Kickoff Atlas", "Atlas parte a gennaio.", ["atlas", "lavoro"])
    await _talk(db_session, 2, "Demo Atlas", "Atlas slitta a marzo.", ["atlas"])
    await _talk(db_session, 5, "Cena", "Pizza da Gino.", ["cena"])
    await db_session.commit()

    assert await topics_named_in(db_session, TEST_USER_ID, "A che punto è ATLAS?") == ["atlas"]
    # One conversation's topic, a word inside another, or no topic at all: no story
    assert await topics_named_in(db_session, TEST_USER_ID, "Com'era la cena?") == []
    assert await topics_named_in(db_session, TEST_USER_ID, "atlassiano") == []

    memory = await retrieve_memory_context(
        db_session, TEST_USER_ID, "A che punto è Atlas?",
        embedding_service=MockEmbeddingService(),
    )
    story = memory.context.split("Topics asked about")[1]
    assert story.index("Atlas slitta a marzo") < story.index("Atlas parte a gennaio")


async def test_another_user_s_topics_are_never_named(db_session: AsyncSession):
    await _talk(db_session, 1, "Atlas", "Atlas.", ["atlas"])
    await _talk(db_session, 2, "Atlas", "Atlas.", ["atlas"])
    await db_session.commit()

    other = TEST_USER_ID.__class__(int=TEST_USER_ID.int + 1)
    assert await topics_named_in(db_session, other, "Atlas?") == []
