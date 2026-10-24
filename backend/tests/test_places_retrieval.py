"""Memory answers know the places visited: a "Places visited" section and the place of
each conversation; outside assistants (MCP) never see either."""

from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from app.services import places
from app.services.memory_retrieval import retrieve_memory_context
from app.services.temporal import DateRange
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation
from tests.mocks import MockEmbeddingService
from tests.test_mcp_tools import _chunk, _key, call

NOW = datetime.now(timezone.utc).replace(second=0, microsecond=0)
DAYS_AGO_3 = NOW - timedelta(days=3)


def _stay(key, arrived, minutes, name, address):
    return places.VisitIn(
        key, arrived, arrived + timedelta(minutes=minutes), 45.46, 9.19, 20.0, name, address
    )


async def _visits(db):
    await places.record_visits(
        db, TEST_USER_ID,
        [
            _stay("gino", DAYS_AGO_3, 190, "Pizzeria Da Gino", "Via Garibaldi 5, Milano"),
            _stay("gym1", NOW - timedelta(days=4), 75, "Virgin Active", "Corso Como 15, Milano"),
            _stay("gym2", NOW - timedelta(days=8), 70, "Virgin Active", "Corso Como 15, Milano"),
            _stay("street", NOW - timedelta(days=5), 30, None, "Via Tortona 31, Milano"),
        ],
        source="ios", now=NOW,
    )
    await db.commit()


async def _ask(db, question, **kwargs):
    return await retrieve_memory_context(
        db, TEST_USER_ID, question, embedding_service=MockEmbeddingService(), **kwargs
    )


async def test_a_period_lists_its_visits(db_session):
    await _visits(db_session)
    day = DateRange(date_from=DAYS_AGO_3 - timedelta(hours=2), date_to=DAYS_AGO_3 + timedelta(hours=6))

    memory = await _ask(db_session, "dove siamo stati sabato sera?", date_range=day)

    assert "Places visited" in memory.context
    assert "Pizzeria Da Gino (Via Garibaldi 5, Milano)" in memory.context
    assert "Virgin Active" not in memory.context


async def test_a_where_question_lists_the_places_with_their_last_visit(db_session):
    await _visits(db_session)

    memory = await _ask(db_session, "Quando sono andato in palestra l'ultima volta?")

    assert "Virgin Active (Corso Como 15, Milano)" in memory.context
    assert "2 visits" in memory.context
    # Latest first: the pizzeria (3 days ago) before the gym (4 days ago)
    assert memory.context.index("Pizzeria Da Gino") < memory.context.index("Virgin Active")
    assert "Via Tortona 31, Milano" in memory.context


async def test_a_question_naming_a_place_finds_it(db_session):
    await _visits(db_session)

    memory = await _ask(db_session, "How often did I go to Virgin Active?")

    assert "Virgin Active" in memory.context


async def test_a_question_not_about_places_has_no_places(db_session):
    await _visits(db_session)
    conversation, _ = await make_conversation(db_session, started_at=NOW - timedelta(days=1))
    await _chunk(db_session, conversation, "Il budget arriva venerdì")

    memory = await _ask(db_session, "Cosa ha detto Ada del budget?")

    assert "Places visited" not in memory.context


async def test_a_conversation_carries_its_place(db_session):
    await _visits(db_session)
    dinner, _ = await make_conversation(
        db_session, started_at=DAYS_AGO_3 + timedelta(minutes=30), minutes=60,
        title="Cena con Marco", summary="Marco racconta del viaggio.",
    )
    await _chunk(db_session, dinner, "Marco racconta del viaggio in Giappone")

    memory = await _ask(db_session, "Di cosa abbiamo parlato a cena?")

    assert "Cena con Marco (at Pizzeria Da Gino): Marco racconta del viaggio." in memory.context


async def test_only_places_is_still_an_answer(db_session):
    await _visits(db_session)

    memory = await _ask(
        db_session, "dove sono stato?",
        date_range=DateRange(date_from=NOW - timedelta(days=9), date_to=NOW),
    )

    assert memory.context != ""


async def test_mcp_sees_no_places(client, auth_headers, db_session):
    await _visits(db_session)
    dinner, _ = await make_conversation(
        db_session, started_at=DAYS_AGO_3 + timedelta(minutes=30), minutes=60,
        title="Cena con Marco", summary="Marco racconta del viaggio.",
    )
    await _chunk(db_session, dinner, "Marco racconta del viaggio in Giappone")
    key = await _key(client, auth_headers)

    ours = await _ask(db_session, "dove siamo stati a cena con Marco?")
    with patch("app.mcp.tools.get_embedding_service", return_value=MockEmbeddingService()):
        theirs = await call(client, key, "search_memory", {"query": "dove siamo stati a cena?"})

    assert "Pizzeria Da Gino" in ours.context
    text = str(theirs)
    assert "Cena con Marco" in text
    for secret in ("Pizzeria", "Garibaldi", "Virgin", "Tortona", "Places visited"):
        assert secret not in text


async def test_places_that_cannot_be_read_leave_the_rest_of_the_answer(db_session):
    await _visits(db_session)
    dinner, _ = await make_conversation(
        db_session, started_at=DAYS_AGO_3 + timedelta(minutes=30), minutes=60,
        title="Cena con Marco", summary="Marco racconta del viaggio.",
    )
    await _chunk(db_session, dinner, "Marco racconta del viaggio in Giappone")

    with patch("app.services.places.visits_between", side_effect=RuntimeError("down")):
        memory = await _ask(db_session, "dove siamo stati a cena?")

    assert "Cena con Marco: Marco racconta del viaggio." in memory.context
    assert "Places visited" not in memory.context


def test_the_prompts_know_the_places():
    from app.actions.availability import INTENT_PROMPT
    from app.services.about_echo import about_echo
    from app.services.memory_answers import rag_system_prompt

    assert "'Places visited'" in rag_system_prompt(None)
    assert "Profile → Places visited" in about_echo([])
    assert "where the user was" in INTENT_PROMPT
