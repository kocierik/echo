"""Memory answers find Saved things too; outside assistants (MCP) never see their place."""

from datetime import datetime, timedelta
from unittest.mock import patch

from app.services import saved
from app.services.memory_retrieval import retrieve_memory_context
from app.services.temporal import DateRange
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService
from tests.test_mcp_tools import _key, call

PLACE = {"latitude": 45.46, "longitude": 9.19, "accuracy_m": 10, "address": "Via Roma 12, Milano"}


async def _save(db, list_name, title, **kwargs):
    item, _ = await saved.save_item(
        db, TEST_USER_ID, list_name=list_name, title=title, moment=saved.Moment(source="voice"),
        embedding_service=MockEmbeddingService(), **kwargs,
    )
    await db.commit()
    return item


async def test_a_question_about_a_saved_wine_finds_it(db_session):
    await _save(db_session, "Vini", "Barolo 2019", details="Cantina Rinaldi",
                people=[{"name": "Marco", "id": None}])
    await _save(db_session, "Libri", "Dune")

    memory = await retrieve_memory_context(
        db_session, TEST_USER_ID, "cos'era quel vino con Marco?",
        embedding_service=MockEmbeddingService(),
    )

    assert "Saved things" in memory.context
    assert "Barolo 2019" in memory.context and "Cantina Rinaldi" in memory.context
    assert "Dune" not in memory.context


async def test_the_period_of_the_question_narrows_the_saved_things(db_session):
    old = await _save(db_session, "Vini", "Vermentino")
    old.created_at = old.created_at - timedelta(days=30)
    await db_session.commit()
    now = datetime.now(old.created_at.tzinfo)

    memory = await retrieve_memory_context(
        db_session, TEST_USER_ID, "che vino ho salvato?",
        date_range=DateRange(date_from=now - timedelta(days=7), date_to=now),
        embedding_service=MockEmbeddingService(),
    )

    assert "Vermentino" not in memory.context


async def test_echo_sees_the_place_and_outside_assistants_do_not(db_session):
    await _save(db_session, "La macchina", "Macchina", place=PLACE)

    ours = await retrieve_memory_context(
        db_session, TEST_USER_ID, "dov'è la macchina?", embedding_service=MockEmbeddingService(),
    )
    theirs = await retrieve_memory_context(
        db_session, TEST_USER_ID, "dov'è la macchina?", embedding_service=MockEmbeddingService(),
        include_places=False,
    )

    assert "Via Roma 12" in ours.context
    assert "Macchina" in theirs.context and "Via Roma" not in theirs.context


async def test_mcp_search_never_returns_a_saved_place(client, auth_headers, db_session):
    await _save(db_session, "La macchina", "Macchina", place=PLACE)
    key = await _key(client, auth_headers)

    with patch("app.mcp.tools.get_embedding_service", MockEmbeddingService):
        found = await call(client, key, "search_memory", {"query": "dove ho lasciato la macchina"})

    assert "Macchina" in found["quoted"] and "Via Roma" not in found["quoted"]
