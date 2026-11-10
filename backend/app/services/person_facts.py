"""Extract transcript-grounded facts about saved people."""

import logging
import re
import unicodedata
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.voice import strip_speaker_tag
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.entity_mention import EntityMention
from app.models.person_fact import PersonFact
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.fact_suggestions import is_sensitive
from app.services.llm_base import LLMMessage, LLMService
from app.services.people import names_person
from app.workers.retry import retry_with_backoff

logger = logging.getLogger(__name__)

MAX_FACTS_PER_CONVERSATION = 5
CATEGORIES = ("work", "family", "home", "interests", "plans", "other")
MAX_CONTEXT_LINES = 40
REJECTED_CONTEXT_LIMIT = 8
REJECTED_CONTEXT_DAYS = 30

_SENTENCE_BOUNDARY = re.compile(r"(?<=[.!?。！？])\s+")
_SPEAKER_PREFIX = {"self": "[You] ", "other": "[Others] "}

PROMPT = (
    "Extract lasting facts about the saved people named in this conversation. "
    "Only include facts about a person explicitly listed below and supported by an "
    "exact sentence in the provided transcript lines. Keep stable information about who "
    "they are, work, family, home, interests, or plans; leave out one-off events and "
    "temporary details. Never infer facts. Never include sensitive information about "
    "health, politics, religion, sex life or orientation, ethnicity, or money troubles. "
    "Write each short fact in English, but quote the exact sentence in its original "
    "language. Use a category from work, family, home, interests, plans, other; use "
    "'other' when none fits. Set replaces only when a new fact contradicts or updates a "
    "listed current fact, and use that fact's id; otherwise use null. Do not repeat "
    "current or rejected facts, including the rejected facts' meaning. Return at most "
    f"{MAX_FACTS_PER_CONVERSATION} facts. Reply with JSON only in this schema: "
    '{"facts":[{"person":"<saved person name>","text":"<fact>","category":"<category>",'
    '"quote":"<exact transcript sentence>","replaces":"<current fact UUID or null>"}]}'
)


async def current_facts(
    db: AsyncSession, user_id: uuid.UUID, person_id: uuid.UUID
) -> list[PersonFact]:
    """Return a user's current facts about one person, newest first."""
    return list(
        await db.scalars(
            select(PersonFact)
            .where(
                PersonFact.user_id == user_id,
                PersonFact.person_id == person_id,
                PersonFact.status == "current",
            )
            .order_by(PersonFact.created_at.desc(), PersonFact.id.desc())
        )
    )


async def earlier_facts(
    db: AsyncSession, user_id: uuid.UUID, person_id: uuid.UUID
) -> list[PersonFact]:
    """Return a user's superseded facts about one person, newest first."""
    return list(
        await db.scalars(
            select(PersonFact)
            .where(
                PersonFact.user_id == user_id,
                PersonFact.person_id == person_id,
                PersonFact.status == "superseded",
            )
            .order_by(PersonFact.created_at.desc(), PersonFact.id.desc())
        )
    )


def _normalized_quote(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    value = " ".join(value.split())
    start, end = 0, len(value)
    while start < end and unicodedata.category(value[start]).startswith("P"):
        start += 1
    while end > start and unicodedata.category(value[end - 1]).startswith("P"):
        end -= 1
    return value[start:end]


def _source_sentences(text: str) -> list[str]:
    return [sentence.strip() for sentence in _SENTENCE_BOUNDARY.split(text) if sentence.strip()]


def _transcript_line(text: str, speaker: str | None) -> tuple[str, str]:
    """Return the speaker-tagged line for the prompt and its exact untagged source."""
    source = strip_speaker_tag(text)
    if source != text:
        return text.strip(), source
    prefix = _SPEAKER_PREFIX.get(speaker or "")
    return f"{prefix}{text.strip()}" if prefix else text.strip(), text.strip()


async def _saved_people(db: AsyncSession, conversation: Conversation) -> list[Entity]:
    result = await db.scalars(
        select(Entity)
        .join(EntityMention, EntityMention.entity_id == Entity.id)
        .where(
            Entity.user_id == conversation.user_id,
            Entity.entity_type == "person",
            EntityMention.conversation_id == conversation.id,
        )
        .order_by(Entity.name, Entity.id)
    )
    return list(result.unique())


async def _recently_rejected(
    db: AsyncSession, user_id: uuid.UUID, person_id: uuid.UUID, now: datetime
) -> list[PersonFact]:
    return list(
        await db.scalars(
            select(PersonFact)
            .where(
                PersonFact.user_id == user_id,
                PersonFact.person_id == person_id,
                PersonFact.status == "rejected",
                PersonFact.created_at >= now - timedelta(days=REJECTED_CONTEXT_DAYS),
            )
            .order_by(PersonFact.created_at.desc(), PersonFact.id.desc())
            .limit(REJECTED_CONTEXT_LIMIT)
        )
    )


async def extract_person_facts(
    db: AsyncSession, llm: LLMService, conversation: Conversation
) -> list[PersonFact]:
    """Add verified facts about saved people in a conversation; the caller commits."""
    people = await _saved_people(db, conversation)
    if not people:
        return []

    transcript_rows = await db.execute(
        select(Transcription.text, Segment.id, Segment.speaker)
        .join(Segment, Segment.id == Transcription.segment_id)
        .where(Segment.conversation_id == conversation.id)
        .order_by(Segment.recorded_at, Segment.id)
    )
    lines = []
    for text, segment_id, speaker in transcript_rows.all():
        if not text or not text.strip():
            continue
        display, source = _transcript_line(text, speaker)
        lines.append(
            {
                "segment_id": segment_id,
                "display": display,
                "source": source,
                "sentences": _source_sentences(source),
            }
        )

    person_line_indexes: dict[uuid.UUID, set[int]] = {}
    for person in people:
        matching = {
            index
            for index, line in enumerate(lines)
            if names_person(person.name, line["source"])
        }
        if matching:
            person_line_indexes[person.id] = matching
    if not person_line_indexes:
        return []

    person_context_indexes: dict[uuid.UUID, set[int]] = {}
    for person_id, matching in person_line_indexes.items():
        indexes = set()
        for index in matching:
            indexes.update(range(max(0, index - 1), min(len(lines), index + 2)))
        person_context_indexes[person_id] = indexes
    people_by_id = {person.id: person for person in people}
    context_people_by_index: dict[int, set[uuid.UUID]] = {}
    for person_id, indexes in person_context_indexes.items():
        for index in indexes:
            context_people_by_index.setdefault(index, set()).add(person_id)
    included_indexes = sorted(context_people_by_index)[:MAX_CONTEXT_LINES]

    now = datetime.now(timezone.utc)
    current_by_person: dict[uuid.UUID, list[PersonFact]] = {}
    rejected_by_person: dict[uuid.UUID, list[PersonFact]] = {}
    for person in people:
        current_by_person[person.id] = await current_facts(
            db, conversation.user_id, person.id
        )
        rejected_by_person[person.id] = await _recently_rejected(
            db, conversation.user_id, person.id, now
        )

    person_context = []
    for person in people:
        current = current_by_person[person.id]
        rejected = rejected_by_person[person.id]
        person_context.append(
            f"- {person.name}\n"
            "  Current facts:\n"
            + (
                "\n".join(
                    f"    - id={fact.id} [{fact.category}] {fact.text}" for fact in current
                )
                if current
                else "    - (none)"
            )
            + "\n  Never again (rejected):\n"
            + (
                "\n".join(f"    - {fact.text}" for fact in rejected)
                if rejected
                else "    - (none)"
            )
        )
    transcript_context = "\n".join(
        f"[{index + 1}] {lines[index]['display']} "
        f"(context for: {', '.join(
            people_by_id[person_id].name
            for person_id in sorted(context_people_by_index[index], key=str)
        )})"
        for index in included_indexes
    )
    messages = [
        LLMMessage(role="system", content=PROMPT),
        LLMMessage(
            role="user",
            content=(
                "Saved people and their memory:\n"
                + "\n".join(person_context)
                + "\n\nTranscript lines (speaker tags are not part of quotes; "
                "quotes must match an exact sentence):\n"
                + transcript_context
            ),
        ),
    ]
    answer = await retry_with_backoff(
        llm.complete_json,
        messages,
        operation_name=f"Person facts conversation {conversation.id}",
    )
    candidates = answer.get("facts") if isinstance(answer, dict) else None
    if not isinstance(candidates, list):
        return []

    people_by_name = {
        unicodedata.normalize("NFKC", person.name).casefold(): person for person in people
    }
    current_ids = {
        person.id: {fact.id: fact for fact in current_by_person[person.id]}
        for person in people
    }
    current_texts = {
        person.id: {fact.text.casefold() for fact in current_by_person[person.id]}
        for person in people
    }
    kept: list[PersonFact] = []

    def reject(reason: str) -> None:
        logger.info(
            "[PersonFacts] Rejected candidate for conversation %s: %s",
            conversation.id,
            reason,
        )

    for candidate in candidates[:MAX_FACTS_PER_CONVERSATION]:
        if not isinstance(candidate, dict):
            reject("invalid_candidate")
            continue
        person_name = candidate.get("person")
        person = (
            people_by_name.get(unicodedata.normalize("NFKC", person_name).casefold())
            if isinstance(person_name, str)
            else None
        )
        if person is None:
            reject("person_not_saved")
            continue
        text = candidate.get("text")
        text = text.strip() if isinstance(text, str) else ""
        if not text or len(text) > 200:
            reject("invalid_text")
            continue
        quote = candidate.get("quote")
        normalized = _normalized_quote(quote) if isinstance(quote, str) else ""
        matched_line = None
        matched_sentence = None
        if normalized:
            for index in included_indexes:
                if person.id not in context_people_by_index[index]:
                    continue
                line = lines[index]
                for sentence in line["sentences"]:
                    if _normalized_quote(sentence) == normalized:
                        matched_line = line
                        matched_sentence = sentence
                        break
                if matched_line is not None:
                    break
        if matched_line is None or matched_sentence is None:
            reject("quote_not_grounded")
            continue
        if is_sensitive(text) or is_sensitive(quote) or is_sensitive(matched_sentence):
            reject("sensitive")
            continue
        if text.casefold() in current_texts[person.id]:
            reject("duplicate")
            continue

        replaces_id = None
        raw_replaces = candidate.get("replaces")
        if raw_replaces:
            try:
                proposed_id = uuid.UUID(str(raw_replaces))
            except (TypeError, ValueError, AttributeError):
                proposed_id = None
            if proposed_id in current_ids[person.id]:
                replaces_id = proposed_id

        category = candidate.get("category")
        if not isinstance(category, str) or category not in CATEGORIES:
            category = "other"

        fact = PersonFact(
            id=uuid.uuid4(),
            user_id=conversation.user_id,
            person_id=person.id,
            text=text,
            category=category,
            quote=matched_sentence,
            segment_id=matched_line["segment_id"],
            conversation_id=conversation.id,
            status="current",
        )
        db.add(fact)
        await db.flush()
        kept.append(fact)
        current_texts[person.id].add(text.casefold())

        if replaces_id is not None:
            replaced = current_ids[person.id][replaces_id]
            replaced.status = "superseded"
            replaced.superseded_by = fact.id
            del current_ids[person.id][replaces_id]

    return kept
