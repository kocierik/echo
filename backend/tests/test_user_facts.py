"""About you: facts about the user, kept (in every answer) or suggested (waiting); the app
manages them and the agent remembers or forgets one when asked."""

import uuid

import pytest
from sqlalchemy import select

from app.actions.fact_tools import FORGET, REMEMBER, run_fact_tool
from app.models.user_fact import UserFact
from app.services import user_facts
from app.services.personal import personal_context
from tests.conftest import TEST_USER_ID


async def _fact(db, text, status="kept", user_id=TEST_USER_ID, source="you"):
    fact = UserFact(user_id=user_id, text=text, status=status, source=source)
    db.add(fact)
    await db.commit()
    return fact


async def test_the_app_lists_kept_facts_and_suggestions(client, auth_headers, db_session):
    await _fact(db_session, "Lavora come sviluppatore a Milano")
    await _fact(db_session, "È vegetariano", status="suggested", source="conversation")
    await _fact(db_session, "Someone else's", user_id=uuid.uuid4())

    body = (await client.get("/api/facts", headers=auth_headers)).json()

    assert [f["text"] for f in body["kept"]] == ["Lavora come sviluppatore a Milano"]
    assert [f["text"] for f in body["suggestions"]] == ["È vegetariano"]
    assert body["suggestions"][0]["source"] == "conversation"


async def test_add_edit_delete(client, auth_headers):
    added = await client.post("/api/facts", headers=auth_headers, json={"text": "  Ha due figli "})
    assert added.status_code == 201
    fact = added.json()
    assert (fact["text"], fact["status"], fact["source"]) == ("Ha due figli", "kept", "you")

    edited = await client.patch(
        f"/api/facts/{fact['id']}", headers=auth_headers, json={"text": "Ha tre figli"}
    )
    assert edited.json()["text"] == "Ha tre figli"

    assert (
        await client.delete(f"/api/facts/{fact['id']}", headers=auth_headers)
    ).status_code == 204
    assert (await client.get("/api/facts", headers=auth_headers)).json()["kept"] == []


async def test_a_suggestion_is_kept_or_discarded(client, auth_headers, db_session):
    keep = await _fact(db_session, "Gioca a padel il giovedì", status="suggested")
    drop = await _fact(db_session, "Abita a Torino", status="suggested")

    kept = await client.post(f"/api/facts/{keep.id}/keep", headers=auth_headers)
    await client.delete(f"/api/facts/{drop.id}", headers=auth_headers)

    assert kept.json()["status"] == "kept"
    body = (await client.get("/api/facts", headers=auth_headers)).json()
    assert [f["text"] for f in body["kept"]] == ["Gioca a padel il giovedì"]
    assert body["suggestions"] == []


@pytest.mark.parametrize("text", ["", "   ", "x" * 201])
async def test_an_empty_or_too_long_fact_is_refused(client, auth_headers, text):
    response = await client.post("/api/facts", headers=auth_headers, json={"text": text})

    assert response.status_code == 422


async def test_past_sixty_kept_facts_one_more_is_refused(client, auth_headers, db_session):
    for i in range(user_facts.MAX_KEPT):
        db_session.add(
            UserFact(user_id=TEST_USER_ID, text=f"Fatto {i}", status="kept", source="you")
        )
    await db_session.commit()

    response = await client.post("/api/facts", headers=auth_headers, json={"text": "Uno di più"})

    assert response.status_code == 409


async def test_someone_elses_fact_is_404(client, auth_headers, db_session):
    other = await _fact(db_session, "Not yours", user_id=uuid.uuid4())

    assert (await client.delete(f"/api/facts/{other.id}", headers=auth_headers)).status_code == 404
    assert (
        await client.patch(f"/api/facts/{other.id}", headers=auth_headers, json={"text": "x"})
    ).status_code == 404


async def test_every_answer_knows_the_kept_facts_only(db_session):
    await _fact(db_session, "Lavora come sviluppatore a Milano")
    await _fact(db_session, "È vegetariano", status="suggested")

    prompt = await personal_context(db_session, TEST_USER_ID)

    assert "Lavora come sviluppatore a Milano" in prompt
    assert "vegetariano" not in prompt


async def test_without_facts_the_prompt_is_as_before(db_session):
    assert await personal_context(db_session, uuid.uuid4()) == ""


async def test_the_agent_remembers_and_forgets_when_asked(db_session):
    remembered = await run_fact_tool(
        db_session, TEST_USER_ID, REMEMBER, {"fact": "È vegetariano"},
        request="Echo, ricordati che sono vegetariano",
    )
    await db_session.commit()
    assert remembered.ok

    [fact] = (
        await db_session.scalars(select(UserFact).where(UserFact.user_id == TEST_USER_ID))
    ).all()
    assert (fact.text, fact.status, fact.source) == ("È vegetariano", "kept", "echo")

    forgotten = await run_fact_tool(db_session, TEST_USER_ID, FORGET, {"fact": "vegetariano"})
    await db_session.commit()
    assert forgotten.ok
    # Out of every answer; kept as discarded so it is not suggested again
    assert fact.status == "discarded"


async def test_forgetting_something_never_said_says_so(db_session):
    result = await run_fact_tool(db_session, TEST_USER_ID, FORGET, {"fact": "vive su Marte"})

    assert result.ok is False


async def test_remembering_the_same_fact_twice_keeps_one(db_session):
    await run_fact_tool(db_session, TEST_USER_ID, REMEMBER, {"fact": "È vegetariano"})
    await run_fact_tool(db_session, TEST_USER_ID, REMEMBER, {"fact": "è vegetariano."})
    await db_session.commit()

    facts = (
        await db_session.scalars(select(UserFact).where(UserFact.user_id == TEST_USER_ID))
    ).all()
    assert len(facts) == 1


def test_asking_to_remember_or_forget_a_fact_may_need_the_agent():
    from app.routers.query import might_need_tools

    assert might_need_tools("ricordati che sono vegetariano", [])
    assert might_need_tools("dimentica che lavoro a Milano", [])
    assert might_need_tools("forget that I live in Turin", [])


def test_the_intent_check_sends_a_fact_to_echo_s_own_tools():
    from app.actions.availability import INTENT_PROMPT

    assert "dimentica che lavoro a Milano" in INTENT_PROMPT
