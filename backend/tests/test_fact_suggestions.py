"""Echo noticed: once a conversation is summarized, the facts the user says about themselves
are suggested, never kept until the user keeps them; nothing sensitive, nothing known."""

import json
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.models.segment import Segment
from app.models.user_fact import UserFact
from app.services.fact_suggestions import suggest_facts
from app.workers.summaries import summarize_closed_conversations
from tests.conftest import TEST_USER_ID, test_session
from tests.factories import make_conversation

STARTED = datetime(2026, 10, 27, 10, tzinfo=timezone.utc)


class _LLM:
    def __init__(self, facts):
        self.facts = facts
        self.asked: list[str] = []

    async def complete_json(self, messages, temperature=0.1):
        system = messages[0].content
        if "lasting facts" in system:
            self.asked.append(messages[-1].content)
            return {"facts": self.facts}
        return {"title": "Pranzo", "summary": "Si parla di lavoro.", "emoji": "🍝"}


async def _facts(status=None):
    async with test_session() as db:
        query = select(UserFact).where(UserFact.user_id == TEST_USER_ID)
        if status:
            query = query.where(UserFact.status == status)
        return list(await db.scalars(query.order_by(UserFact.created_at)))


async def _conversation(db):
    texts = (
        "[You] Io lavoro come sviluppatore a Milano da tre anni, sai.",
        "[Others] Ah bello, io invece faccio la commercialista.",
        "[You] Mia figlia Sara inizia la scuola a settembre, sono vegetariano da anni.",
    )
    conversation, lines = await make_conversation(
        db, started_at=STARTED, texts=texts, summary=None, title=None
    )
    for line, speaker in zip(lines, ("self", "other", "self")):
        segment = await db.get(Segment, line.segment_id)
        segment.speaker = speaker
    # Transcribed again whole already: the summary waits for that (workers/summaries.py)
    conversation.retranscribed_at = STARTED
    await db.commit()
    return conversation


async def test_only_the_users_own_words_are_read_and_facts_wait_for_the_user(db_session):
    conversation = await _conversation(db_session)
    llm = _LLM(["Lavora come sviluppatore a Milano", "Ha una figlia, Sara"])

    added = await suggest_facts(db_session, llm, conversation)
    await db_session.commit()

    assert "sviluppatore" in llm.asked[0] and "commercialista" not in llm.asked[0]
    assert [f.text for f in added] == ["Lavora come sviluppatore a Milano", "Ha una figlia, Sara"]
    suggested = await _facts("suggested")
    assert [f.source for f in suggested] == ["conversation", "conversation"]
    assert suggested[0].conversation_id == conversation.id
    assert await _facts("kept") == []


async def test_at_most_three_and_nothing_known_or_sensitive(db_session):
    conversation = await _conversation(db_session)
    db_session.add(
        UserFact(user_id=TEST_USER_ID, text="È vegetariano", status="kept", source="you")
    )
    await db_session.commit()
    llm = _LLM(
        [
            "è vegetariano",
            "Soffre di diabete",
            "Vota per il partito verde",
            "Lavora come sviluppatore a Milano",
            "Ha una figlia, Sara",
            "Gioca a padel",
            "Vive a Milano",
        ]
    )

    added = await suggest_facts(db_session, llm, conversation)

    assert [f.text for f in added] == [
        "Lavora come sviluppatore a Milano",
        "Ha una figlia, Sara",
        "Gioca a padel",
    ]
    # What is already known is told to the model too
    assert "È vegetariano" in llm.asked[0]


async def test_a_discarded_suggestion_is_not_suggested_again(client, auth_headers, db_session):
    conversation = await _conversation(db_session)
    [first] = await suggest_facts(db_session, _LLM(["Gioca a padel"]), conversation)
    await db_session.commit()
    await client.delete(f"/api/facts/{first.id}", headers=auth_headers)

    again = await suggest_facts(db_session, _LLM(["Gioca a padel"]), conversation)

    assert again == []
    listed = (await client.get("/api/facts", headers=auth_headers)).json()
    assert listed["suggestions"] == []


async def test_old_suggestions_make_room_past_twenty(db_session):
    conversation = await _conversation(db_session)
    for i in range(20):
        db_session.add(
            UserFact(
                user_id=TEST_USER_ID,
                text=f"Vecchio {i}",
                status="suggested",
                source="conversation",
                created_at=STARTED - timedelta(days=30 - i),
            )
        )
    await db_session.commit()

    await suggest_facts(db_session, _LLM(["Gioca a padel"]), conversation)
    await db_session.commit()

    suggested = await _facts("suggested")
    assert len(suggested) == 20
    assert "Vecchio 0" not in [f.text for f in suggested]
    assert suggested[-1].text == "Gioca a padel"


async def test_a_bad_answer_suggests_nothing(db_session):
    conversation = await _conversation(db_session)

    class _Broken:
        async def complete_json(self, messages, temperature=0.1):
            raise ValueError("not json")

    assert await suggest_facts(db_session, _Broken(), conversation) == []


async def test_summarizing_a_closed_conversation_suggests_its_facts():
    async with test_session() as db:
        await _conversation(db)
    llm = _LLM(["Lavora come sviluppatore a Milano"])

    await summarize_closed_conversations(
        now=STARTED + timedelta(hours=3), session_factory=test_session, llm_service=llm
    )

    assert [f.text for f in await _facts("suggested")] == ["Lavora come sviluppatore a Milano"]
    assert json.dumps(llm.asked)  # the facts call was made once
    assert len(llm.asked) == 1
