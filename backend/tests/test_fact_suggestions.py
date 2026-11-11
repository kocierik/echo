"""Echo noticed: once a conversation is summarized, the facts the user says about themselves
are suggested, never kept until the user keeps them; nothing sensitive, nothing known."""

import json
import uuid
from datetime import datetime, timedelta, timezone
from functools import partial

import pytest
from sqlalchemy import select

from app.models.entity import Entity
from app.models.entity_mention import EntityMention
from app.models.person_fact import PersonFact
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


async def test_summarizing_stores_normalized_topics_without_saved_person_names():
    async with test_session() as db:
        conversation = await _conversation(db)
        person = Entity(
            user_id=TEST_USER_ID,
            entity_type="person",
            name="Marco",
            metadata_={},
        )
        db.add(person)
        await db.flush()
        db.add(EntityMention(entity_id=person.id, conversation_id=conversation.id))
        await db.commit()

    class _TopicLLM(_LLM):
        async def complete_json(self, messages, temperature=0.1):
            return {
                "title": "Pranzo",
                "summary": "Si parla di lavoro.",
                "emoji": "🍝",
                "topics": ["Atlas", " atlas ", "Marco"],
            }

    await summarize_closed_conversations(
        now=STARTED + timedelta(hours=3),
        session_factory=test_session,
        llm_service=_TopicLLM([]),
    )

    async with test_session() as db:
        saved = await db.get(type(conversation), conversation.id)
        assert saved.topics == ["atlas"]


class _PeopleLLM:
    def __init__(self, person_facts=()):
        self.person_facts = list(person_facts)
        self.person_prompts: list[str] = []

    async def complete_json(self, messages, temperature=0.1):
        system = messages[0].content
        if "You organize the user's conversations." in system:
            return {"title": "Marco", "summary": "Marco lavora in Acme.", "emoji": "💼"}
        if "From the user's own words" in system:
            return {"facts": []}
        if "saved people" in system.lower():
            self.person_prompts.append(messages[-1].content)
            return {"facts": self.person_facts}
        raise AssertionError(f"Unexpected LLM prompt: {system}")


PERSON_LINES = (
    "[You] Oggi ho incontrato Marco.",
    "[Others] Marco lavora in Acme.",
)


async def _person_conversation(db, *, lines=PERSON_LINES, mention=True):
    conversation, transcriptions = await make_conversation(
        db, started_at=STARTED, texts=lines, summary=None, title=None
    )
    for transcription, line in zip(transcriptions, lines):
        segment = await db.get(Segment, transcription.segment_id)
        segment.speaker = "self" if line.startswith("[You]") else "other"
    conversation.retranscribed_at = STARTED
    person = Entity(
        user_id=conversation.user_id,
        entity_type="person",
        name="Marco",
        metadata_={},
    )
    db.add(person)
    await db.flush()
    if mention:
        db.add(EntityMention(entity_id=person.id, conversation_id=conversation.id))
    return conversation, person, transcriptions


async def _run_summary(llm):
    return await summarize_closed_conversations(
        now=STARTED + timedelta(hours=3),
        session_factory=test_session,
        llm_service=llm,
    )


async def _conversation_person_facts(conversation_id):
    async with test_session() as db:
        return list(
            await db.scalars(
                select(PersonFact)
                .where(PersonFact.conversation_id == conversation_id)
                .order_by(PersonFact.created_at, PersonFact.id)
            )
        )


def _candidate(text, *, quote="Marco lavora in Acme.", person="Marco", category="work",
               replaces=None):
    return {
        "person": person,
        "text": text,
        "category": category,
        "quote": quote,
        "replaces": replaces,
    }


async def test_a_grounded_fact_is_kept():
    async with test_session() as db:
        conversation, _, transcriptions = await _person_conversation(db)
        await db.commit()
        conversation_id = conversation.id
        source_segment_id = transcriptions[1].segment_id
    llm = _PeopleLLM([
        _candidate(
            "Works at Acme",
            quote="marco lavora in acme",
        )
    ])

    await _run_summary(llm)

    [fact] = await _conversation_person_facts(conversation_id)
    assert fact.text == "Works at Acme"
    assert fact.category == "work"
    assert fact.quote == "Marco lavora in Acme."
    assert fact.segment_id == source_segment_id


async def test_ungrounded_unlisted_sensitive_and_duplicate_facts_are_dropped():
    async with test_session() as db:
        conversation, person, _ = await _person_conversation(db)
        db.add(
            PersonFact(
                user_id=conversation.user_id,
                person_id=person.id,
                text="Works at Acme",
                category="work",
                quote="Marco lavora in Acme.",
                status="current",
            )
        )
        await db.commit()
        conversation_id = conversation.id
    llm = _PeopleLLM([
        _candidate("Uncited fact", quote="Unrelated sentence."),
        _candidate("Lives in Rome", person="Luca"),
        _candidate("Marco is depressed"),
        _candidate("works at acme"),
    ])

    await _run_summary(llm)

    assert await _conversation_person_facts(conversation_id) == []
    assert "Works at Acme" in llm.person_prompts[0]


async def test_a_newer_fact_supersedes():
    async with test_session() as db:
        conversation, person, _ = await _person_conversation(db)
        old_fact = PersonFact(
            user_id=conversation.user_id,
            person_id=person.id,
            text="Lives in Turin",
            category="home",
            quote="Marco vive a Torino.",
            status="current",
        )
        db.add(old_fact)
        await db.flush()
        conversation_id, old_fact_id = conversation.id, old_fact.id
        await db.commit()
    llm = _PeopleLLM([
        _candidate("Lives in Bologna", replaces=str(old_fact_id))
    ])

    await _run_summary(llm)

    [new_fact] = await _conversation_person_facts(conversation_id)
    async with test_session() as db:
        replaced = await db.get(PersonFact, old_fact_id)
    assert replaced.status == "superseded"
    assert replaced.superseded_by == new_fact.id


async def test_replaces_a_fact_that_is_not_current_or_not_theirs():
    async with test_session() as db:
        conversation, person, _ = await _person_conversation(db)
        another_person = Entity(
            user_id=conversation.user_id,
            entity_type="person",
            name="Luca",
            metadata_={},
        )
        db.add(another_person)
        await db.flush()
        other_fact = PersonFact(
            user_id=conversation.user_id,
            person_id=another_person.id,
            text="Lives in Turin",
            category="home",
            quote="Luca vive a Torino.",
            status="current",
        )
        db.add(other_fact)
        conversation_id, other_fact_id = conversation.id, other_fact.id
        await db.commit()
    llm = _PeopleLLM([
        _candidate("Likes jazz", replaces=str(uuid.uuid4())),
        _candidate("Works at Acme", replaces=str(other_fact_id)),
    ])

    await _run_summary(llm)

    assert len(await _conversation_person_facts(conversation_id)) == 2
    async with test_session() as db:
        other_fact = await db.get(PersonFact, other_fact_id)
    assert other_fact.status == "current"
    assert other_fact.superseded_by is None


async def test_rejected_facts_are_told_as_never_again():
    async with test_session() as db:
        conversation, person, _ = await _person_conversation(db)
        db.add(
            PersonFact(
                user_id=conversation.user_id,
                person_id=person.id,
                text="Marco owns a red bicycle",
                category="interests",
                quote="Marco ha una bicicletta rossa.",
                status="rejected",
                created_at=STARTED - timedelta(days=2),
                rejected_at=datetime.now(timezone.utc) - timedelta(days=2),
            )
        )
        await db.commit()
    llm = _PeopleLLM([])

    await _run_summary(llm)

    assert len(llm.person_prompts) == 1
    assert "Marco owns a red bicycle" in llm.person_prompts[0]


async def test_old_fact_rejected_recently_is_in_never_again_context():
    async with test_session() as db:
        conversation, person, _ = await _person_conversation(db)
        db.add(
            PersonFact(
                user_id=conversation.user_id,
                person_id=person.id,
                text="Works at Acme",
                category="work",
                quote="Marco lavora in Acme.",
                status="rejected",
                created_at=STARTED - timedelta(days=60),
                rejected_at=datetime.now(timezone.utc) - timedelta(days=2),
            )
        )
        await db.commit()
    llm = _PeopleLLM([])

    await _run_summary(llm)

    assert "Works at Acme" in llm.person_prompts[0]


async def test_rejection_older_than_context_window_is_not_recreated():
    async with test_session() as db:
        conversation, person, _ = await _person_conversation(db)
        db.add(
            PersonFact(
                user_id=conversation.user_id,
                person_id=person.id,
                text="Works at Acme",
                category="work",
                quote="Marco lavora in Acme.",
                status="rejected",
                created_at=datetime.now(timezone.utc) - timedelta(days=1),
                rejected_at=datetime.now(timezone.utc) - timedelta(days=31),
            )
        )
        await db.commit()
        conversation_id = conversation.id
    llm = _PeopleLLM([_candidate("  works at acme  ")])

    await _run_summary(llm)

    assert "Works at Acme" not in llm.person_prompts[0]
    assert await _conversation_person_facts(conversation_id) == []


async def test_legacy_rejection_without_timestamp_still_suppresses_duplicate():
    async with test_session() as db:
        conversation, person, _ = await _person_conversation(db)
        db.add(
            PersonFact(
                user_id=conversation.user_id,
                person_id=person.id,
                text="Works at Acme",
                category="work",
                quote="Marco lavora in Acme.",
                status="rejected",
                created_at=STARTED - timedelta(days=60),
            )
        )
        await db.commit()
        conversation_id = conversation.id
    llm = _PeopleLLM([_candidate("works at acme")])

    await _run_summary(llm)

    assert "Works at Acme" not in llm.person_prompts[0]
    assert await _conversation_person_facts(conversation_id) == []


async def test_rejected_fact_outside_newest_eight_is_not_recreated():
    async with test_session() as db:
        conversation, person, _ = await _person_conversation(db)
        for index in range(9):
            db.add(
                PersonFact(
                    user_id=conversation.user_id,
                    person_id=person.id,
                    text="Works at Acme" if index == 0 else f"Rejected fact {index}",
                    category="work",
                    quote="Marco lavora in Acme.",
                    status="rejected",
                    created_at=STARTED - timedelta(days=9 - index),
                    rejected_at=STARTED - timedelta(days=9 - index),
                )
            )
        await db.commit()
        conversation_id = conversation.id
    llm = _PeopleLLM([_candidate("works at acme")])

    await _run_summary(llm)

    assert "Works at Acme" not in llm.person_prompts[0]
    assert await _conversation_person_facts(conversation_id) == []


async def test_invalid_fact_log_has_reason_but_no_personal_text(caplog):
    async with test_session() as db:
        conversation, _, _ = await _person_conversation(db)
        await db.commit()
        conversation_id = conversation.id
    private_text = "Marco shared a deeply private detail"
    private_quote = "una citazione strettamente personale"
    llm = _PeopleLLM([
        _candidate(private_text, quote=private_quote)
    ])

    with caplog.at_level("INFO"):
        await _run_summary(llm)

    output = caplog.text
    assert str(conversation_id) in output
    assert "quote_not_grounded" in output
    assert private_text not in output
    assert private_quote not in output


async def test_person_fact_retry_logs_omit_provider_error_messages(
    db_session, monkeypatch, caplog
):
    import app.services.person_facts as person_facts
    from app.workers.retry import RetryExhaustedError, retry_with_backoff

    private_sentinel = "PRIVATE_PERSON_FACT_RETRY_PROVIDER_SENTINEL"

    class _FailingLLM:
        calls = 0

        async def complete_json(self, messages):
            self.calls += 1
            raise RuntimeError(private_sentinel)

    monkeypatch.setattr(
        person_facts,
        "retry_with_backoff",
        partial(
            retry_with_backoff,
            max_attempts=1,
            base_delay=0,
            use_circuit_breaker=False,
        ),
    )
    conversation, _, _ = await _person_conversation(db_session)
    llm = _FailingLLM()

    with pytest.raises(RetryExhaustedError) as caught:
        await person_facts.extract_person_facts(db_session, llm, conversation)

    assert llm.calls == 1
    assert caught.value.attempts == 1
    assert f"Person facts conversation {conversation.id}" in caplog.text
    assert "RuntimeError" in caplog.text
    assert private_sentinel not in caplog.text
    assert str(caught.value.last_error) == "RuntimeError"
    assert caught.value.last_error.__cause__ is None
    assert caught.value.last_error.__suppress_context__


async def test_person_fact_failure_does_not_roll_back_summary(monkeypatch, caplog):
    import app.services.person_facts as person_facts
    from app.workers.retry import RetryExhaustedError

    private_sentinel = "PRIVATE_PROMPT_RESPONSE_SENTINEL"

    async def exhausted(*args, **kwargs):
        raise RetryExhaustedError(ValueError(private_sentinel), 3)

    monkeypatch.setattr(person_facts, "retry_with_backoff", exhausted)
    async with test_session() as db:
        conversation, _, _ = await _person_conversation(db)
        await db.commit()
        conversation_id = conversation.id

    await _run_summary(_PeopleLLM([]))

    async with test_session() as db:
        saved = await db.get(type(conversation), conversation_id)
    assert saved.summary == "Marco lavora in Acme."
    assert str(conversation_id) in caplog.text
    assert "RetryExhaustedError" in caplog.text
    assert private_sentinel not in caplog.text
    assert "Marco lavora in Acme." not in caplog.text


async def test_no_saved_person_no_call():
    async with test_session() as db:
        conversation, _, _ = await _person_conversation(db, mention=False)
        await db.commit()
        conversation_id = conversation.id
    llm = _PeopleLLM([])

    await _run_summary(llm)

    assert llm.person_prompts == []
    assert await _conversation_person_facts(conversation_id) == []


async def test_at_most_five():
    async with test_session() as db:
        conversation, _, _ = await _person_conversation(db)
        await db.commit()
        conversation_id = conversation.id
    candidates = [_candidate(f"Fact {index}") for index in range(7)]

    await _run_summary(_PeopleLLM(candidates))

    assert [fact.text for fact in await _conversation_person_facts(conversation_id)] == [
        f"Fact {index}" for index in range(5)
    ]


async def test_unknown_category_is_other():
    async with test_session() as db:
        conversation, _, _ = await _person_conversation(db)
        await db.commit()
        conversation_id = conversation.id
    llm = _PeopleLLM([
        _candidate("Collects old maps", category="geography")
    ])

    await _run_summary(llm)

    [fact] = await _conversation_person_facts(conversation_id)
    assert fact.category == "other"
