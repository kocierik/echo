"""Memory retrieval: question -> RAG context string + sources (no LLM call).

Shared by POST /api/query, the action agent's search_memory tool and the voice worker.

A question that names a known person ("cosa ha detto Marco?") is answered first from
the conversations that person was mentioned in: similarity alone would favour any
passage about "saying", not the ones with Marco.

The things the user saved (Saved) that match the question are a section of their own,
with their place, except for outside assistants (MCP: `include_places=False`). So are the
places visited (when the user turned them on): the visits of the question's period, or
the places of a question about where the user was; and each conversation listed says
where it happened. Outside assistants see none of it.
"""

import logging
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone

from sqlalchemy import case, func, literal, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.chunk import Chunk
from app.models.conversation import Conversation
from app.models.document import Document, DocumentChunk
from app.models.entity import Entity
from app.services import places
from app.services.people import in_person_conversations, names_person
from app.services.person_facts import current_facts
from app.services.saved import find_items, item_line
from app.services.temporal import DateRange, conversation_overlaps

logger = logging.getLogger(__name__)

# People named in one question that narrow the search; conversations listed per person
MAX_PEOPLE = 3
PERSON_CONVERSATIONS_LISTED = 5
SAVED_LISTED = 5


@dataclass
class MemoryContext:
    """Retrieved memory. context == "" means nothing was found."""

    context: str
    sources: list[dict] = field(default_factory=list)
    date_range: DateRange | None = None


async def retrieve_memory_context(
    db: AsyncSession,
    user_id: uuid.UUID,
    question: str,
    top_k: int = 5,
    date_range: DateRange | None = None,
    embedding_service=None,
    include_places: bool = True,
    include_documents: bool = True,
    document_ids: list[str] | None = None,
) -> MemoryContext:
    """Embed the question, search chunks/entities/summaries/Saved and assemble the context.

    date_range is used as given (the caller resolves explicit filters or NLP extraction).
    embedding_service defaults to the configured one; callers may inject their own.
    Without `include_places` the saved things come without address, and there are no
    places visited (outside assistants).
    """
    if embedding_service is None:
        from app.services.embedding_openai import get_embedding_service

        embedding_service = get_embedding_service()
    question_embedding = await embedding_service.embed(question)
    people = await people_named_in(db, user_id, question)

    # Conversations that overlap the period (not only those starting in it)
    in_period = (
        conversation_overlaps(date_range.date_from, date_range.date_to) if date_range else ()
    )
    terms = search_terms(question)
    best = _passages(user_id, question_embedding, terms, *in_period)
    rows = await _reranked(db, user_id, (await db.execute(best.limit(top_k))).all())

    if people:
        # The named people's conversations first, then a couple of the best others
        about_people = _passages(
            user_id, question_embedding, terms, *in_period,
            or_(*(in_person_conversations(person) for person in people)),
        )
        person_rows = await _reranked(
            db, user_id, (await db.execute(about_people.limit(top_k))).all()
        )
        seen = {row.id for row in person_rows}
        others = [row for row in rows if row.id not in seen]
        rows = person_rows + others[: max(2, top_k - len(person_rows))]

    # Relevant entities (vector + keyword search)
    entities_context = await find_relevant_entities(db, user_id, question, question_embedding)
    people_context = await describe_people(
        db, user_id, people, date_range, include_places=include_places
    )

    # Conversation summaries for matched conversations (high-level context)
    conversation_summaries = ""
    if rows:
        matched_conv_ids = list({row.conversation_id for row in rows})
        summaries_query = (
            select(
                Conversation.id,
                Conversation.title,
                Conversation.summary,
                Conversation.started_at,
                Conversation.ended_at,
            )
            .where(Conversation.id.in_(matched_conv_ids))
            .where(Conversation.summary.isnot(None))
            .where(Conversation.summary != "")  # "" = too short to summarize
            .order_by(Conversation.started_at.desc())
        )
        summaries_result = await db.execute(summaries_query)
        summaries_rows = summaries_result.all()
        if summaries_rows:
            where = (
                await conversation_places(db, user_id, summaries_rows) if include_places else {}
            )
            summary_lines = []
            for s in summaries_rows:
                date_str = s.started_at.strftime("%d/%m/%Y %H:%M")
                title = s.title or "Conversation"
                if s.id in where:
                    title += f" (at {where[s.id]})"
                summary_lines.append(f"- [{date_str}] {title}: {s.summary}")
            conversation_summaries = "\n".join(summary_lines)

    saved_context = await saved_things(
        db, user_id, question, question_embedding, date_range, include_places
    )
    places_context = (
        await places_visited(db, user_id, question, date_range) if include_places else ""
    )
    documents_context = (
        await document_passages(db, user_id, question_embedding, document_ids)
        if include_documents
        else ""
    )

    if not (
        rows or entities_context or people_context or saved_context or places_context
        or documents_context
    ):
        return MemoryContext(context="", sources=[], date_range=date_range)

    context_parts = []
    sources = []

    if people_context:
        context_parts.append(f"People asked about:\n{people_context}")

    if saved_context:
        context_parts.append(
            f"Saved things (what the user asked Echo to keep):\n{saved_context}"
        )

    if places_context:
        context_parts.append(
            "Places visited (from the user's phone: stays of 10 minutes or more, with "
            f"arrival and departure):\n{places_context}"
        )

    if documents_context:
        context_parts.append(
            "From the user's documents (files they added; name the document when you use "
            f"it):\n{documents_context}"
        )

    if conversation_summaries:
        context_parts.append(f"Relevant conversation summaries:\n{conversation_summaries}")

    if entities_context:
        context_parts.append(f"Structured knowledge:\n{entities_context}")

    # Raw transcriptions for detail
    for row in rows:
        context_parts.append(row.text)
        sources.append(
            {
                "conversation_id": row.conversation_id,
                "chunk_id": row.id,
                "text": row.text[:200],
                "similarity": round(float(row.similarity), 4),
                # For the app to say where a passage comes from
                "title": row.conversation_title,
                "started_at": row.conversation_started_at,
            }
        )

    return MemoryContext(
        context="\n\n---\n\n".join(context_parts),
        sources=sources,
        date_range=date_range,
    )


# A document passage joins an answer only this close to the question, so documents never
# crowd out the conversations with something unrelated. Measured on a real CV (English,
# asked in Italian): its passages score 0.32-0.40 for "where did I study", "what is my
# job"; an unrelated question at most 0.30
DOCUMENT_MIN_SIMILARITY = 0.31
DOCUMENT_PASSAGES = 3


async def document_passages(
    db: AsyncSession,
    user_id: uuid.UUID,
    question_embedding: list[float],
    document_ids: list[str] | None = None,
) -> str:
    """The user's document passages closest to the question, each under its document's
    name ("" when none is close enough, or they cannot be read)."""
    similarity = (1 - DocumentChunk.embedding.cosine_distance(question_embedding)).label(
        "similarity"
    )
    try:
        async with db.begin_nested():
            rows = (
                await db.execute(
                    select(DocumentChunk.text, Document.title, similarity)
                    .join(Document, Document.id == DocumentChunk.document_id)
                    .where(
                        DocumentChunk.user_id == user_id,
                        Document.status == "ready",
                        DocumentChunk.embedding.isnot(None),
                        # An assistant's documents only, when it has some
                        *(
                            [Document.id.in_([uuid.UUID(i) for i in document_ids])]
                            if document_ids
                            else []
                        ),
                    )
                    .order_by(DocumentChunk.embedding.cosine_distance(question_embedding))
                    .limit(DOCUMENT_PASSAGES)
                )
            ).all()
    except Exception:
        logger.warning("Could not search the documents for a memory answer", exc_info=True)
        return ""
    return "\n\n".join(
        f'From your document "{row.title}":\n{row.text}'
        for row in rows
        if float(row.similarity) >= DOCUMENT_MIN_SIMILARITY
    )


async def saved_things(
    db: AsyncSession,
    user_id: uuid.UUID,
    question: str,
    question_embedding: list[float],
    date_range: DateRange | None,
    include_places: bool,
) -> str:
    """The saved things matching the question, one line each ("" when none, or when
    they cannot be read: the rest of the memory still answers)."""
    try:
        # A savepoint: a failure here rolls back only this search, so the session stays
        # usable for the rest of the answer
        async with db.begin_nested():
            items = await find_items(
                db,
                user_id,
                query=question,
                date_from=date_range.date_from if date_range else None,
                date_to=date_range.date_to if date_range else None,
                limit=SAVED_LISTED,
                vector=question_embedding,
            )
    except Exception:
        logger.warning("Could not search Saved for a memory answer", exc_info=True)
        return ""
    return "\n".join(item_line(item, include_place=include_places) for item in items)


async def places_visited(
    db: AsyncSession, user_id: uuid.UUID, question: str, date_range: DateRange | None
) -> str:
    """The "Places visited" lines ("" when none fit, or when they cannot be read: the rest
    of the memory still answers)."""
    try:
        async with db.begin_nested():
            return await places.places_context(
                db,
                user_id,
                question,
                date_range.date_from if date_range else None,
                date_range.date_to if date_range else None,
                now=datetime.now(timezone.utc),
            )
    except Exception:
        logger.warning("Could not read the places visited for a memory answer", exc_info=True)
        return ""


async def conversation_places(
    db: AsyncSession, user_id: uuid.UUID, conversations
) -> dict[uuid.UUID, str]:
    """Where each conversation (rows with id, started_at, ended_at) happened, by name or
    address; none when the places cannot be read."""
    try:
        async with db.begin_nested():
            found = await places.places_of(
                db,
                user_id,
                [(c.id, c.started_at, c.ended_at) for c in conversations],
                now=datetime.now(timezone.utc),
            )
    except Exception:
        logger.warning("Could not read where conversations happened", exc_info=True)
        return {}
    return {cid: name for cid, visit in found.items() if (name := places.label(visit))}


# Reciprocal rank fusion: a passage's score is the sum of 1 / (RRF_K + its rank) over the
# rankings it is in. 60 is the constant of the original paper
RRF_K = 60
# The newest conversations, a little: between two passages alike, the recent one
RECENCY_WEIGHT = 0.3
MAX_TERMS = 12
# A passage's words count once they are rare enough: one word found in about a third of
# the passages or fewer (ln 3), or several commoner ones together
MIN_WORDS_SCORE = 1.0
# Words that say nothing of what is asked (Italian and English)
_STOPWORDS = frozenset(
    "che chi cosa come con del della dei delle degli nel nella per una uno gli alla "
    "allo sono era ero hai abbiamo detto dire fatto quando dove quale quali mio mia "
    "the and for with what when where who which was were did does have has had about "
    "said say that this from you your "
    # asking who said something is not asking about "saying"
    "parlato parlare parla dice chiesto talked told asked".split()
)


def search_terms(question: str) -> list[str]:
    """The words of a question worth finding exactly: 3 letters or more, no filler."""
    seen: dict[str, None] = {}
    for word in re.findall(r"\d{2,}|[^\W_]{3,}", question.lower()):
        if word not in _STOPWORDS:
            seen.setdefault(word)
    return list(seen)[:MAX_TERMS]


def _passages(user_id: uuid.UUID, question_embedding, terms: list[str], *conditions):
    """The user's passages for a question, the best first: by meaning (the embedding), by
    the question's own words (a name, a code, "fattura": what meaning alone ranks low)
    and, a little, by how recent, fused by rank. One query: every passage is scored.

    A word counts by how rare it is among the user's passages (Postgres's own ranking
    does not): "parlato" is in half of them and says nothing, "Zefiro" is in one.

    shortcut: scans all the user's passages (their words are kept ready, migration 042),
    fine in the tens of thousands; beyond, take the top of each ranking from its index
    (HNSW, GIN) and fuse those.
    """
    distance = Chunk.embedding.cosine_distance(question_embedding)
    passages = func.count().over()
    words = literal(0.0)
    for term in terms:
        has = case((Chunk.text_words.op("@@")(func.to_tsquery("simple", term)), 1.0), else_=0.0)
        words = words + has * func.ln((passages + 1.0) / (func.sum(has).over() + 1.0))
    matched = (
        select(
            Chunk.id,
            Chunk.conversation_id,
            Chunk.text,
            distance.label("distance"),
            Conversation.title.label("conversation_title"),
            Conversation.started_at.label("conversation_started_at"),
            words.label("words"),
        )
        .join(Conversation, Conversation.id == Chunk.conversation_id)
        .where(Conversation.user_id == user_id)
        .where(Chunk.embedding.isnot(None))
        .where(*conditions)
        .subquery()
    )
    ranked = select(
        matched,
        func.rank().over(order_by=matched.c.distance).label("by_meaning"),
        func.rank().over(order_by=matched.c.words.desc()).label("by_words"),
        func.rank().over(order_by=matched.c.conversation_started_at.desc()).label("by_recency"),
    ).subquery()
    score = (
        1.0 / (RRF_K + ranked.c.by_meaning)
        + case((ranked.c.words >= MIN_WORDS_SCORE, 1.0 / (RRF_K + ranked.c.by_words)), else_=0.0)
        + RECENCY_WEIGHT / (RRF_K + ranked.c.by_recency)
    ).label("score")
    return select(
        ranked.c.id,
        ranked.c.conversation_id,
        ranked.c.text,
        (1 - ranked.c.distance).label("similarity"),
        ranked.c.conversation_title,
        ranked.c.conversation_started_at,
        score,
    ).order_by(score.desc())


async def _reranked(db: AsyncSession, user_id: uuid.UUID, rows: list) -> list:
    """Rows re-ranked by the user's feedback; those rated down are dropped."""
    if not rows:
        return []
    from app.routers.feedback import get_chunk_feedback_scores

    multipliers = await get_chunk_feedback_scores(db, user_id, [row.id for row in rows])
    scored = [
        (row, float(getattr(row, "score", row.similarity)) * multipliers.get(row.id, 1.0))
        for row in rows
        if multipliers.get(row.id, 1.0) != 0.0
    ]
    scored.sort(key=lambda item: item[1], reverse=True)
    return [row for row, _ in scored]


async def people_named_in(
    db: AsyncSession, user_id: uuid.UUID, question: str
) -> list[Entity]:
    """Known people the question names (first name, whole word), most recent first."""
    result = await db.execute(
        select(Entity)
        .where(Entity.user_id == user_id)
        .where(Entity.entity_type == "person")
        .order_by(Entity.updated_at.desc())
    )
    named = [person for person in result.scalars() if names_person(person.name, question)]
    return named[:MAX_PEOPLE]


async def describe_people(
    db: AsyncSession,
    user_id: uuid.UUID,
    people: list[Entity],
    date_range: DateRange | None = None,
    include_places: bool = False,
) -> str:
    """Who each named person is and the latest conversations they were mentioned in (with
    where they happened, given `include_places`)."""
    lines = []
    for person in people:
        line = f"- {person.name}"
        if person.content:
            line += f": {person.content}"
        conversations = select(
            Conversation.id, Conversation.title, Conversation.started_at, Conversation.ended_at
        ).where(
            Conversation.user_id == user_id, in_person_conversations(person)
        )
        if date_range:
            conversations = conversations.where(
                *conversation_overlaps(date_range.date_from, date_range.date_to)
            )
        found = (
            await db.execute(
                conversations.order_by(Conversation.started_at.desc()).limit(
                    PERSON_CONVERSATIONS_LISTED
                )
            )
        ).all()
        if found:
            where = await conversation_places(db, user_id, found) if include_places else {}
            listed = "; ".join(
                f"{row.started_at:%d/%m/%Y %H:%M} {row.title or 'Conversation'}"
                + (f" (at {where[row.id]})" if row.id in where else "")
                for row in found
            )
            line += f". Mentioned in: {listed}"
        lines.append(line)
        facts = await current_facts(db, user_id, person.id)
        lines.extend(
            f"{person.name}: {fact.text} (from {fact.created_at:%Y-%m-%d})"
            for fact in facts[:8]
        )
    return "\n".join(lines)


async def find_relevant_entities(
    db: AsyncSession, user_id: uuid.UUID, question: str, question_embedding: list[float]
) -> str:
    """Find entities relevant to the question using vector similarity + keyword fallback.

    Strategy:
    1. Vector search on entity embeddings (semantic match)
    2. Keyword fallback for entities without embeddings
    3. Merge and deduplicate results

    Returns a formatted string with entity info, or empty string if none found.
    """
    found_entities = []

    # 1. Vector search on entities with embeddings
    vector_query = (
        select(
            Entity,
            (1 - Entity.embedding.cosine_distance(question_embedding)).label("similarity"),
        )
        .where(Entity.user_id == user_id)
        .where(Entity.embedding.isnot(None))
        .order_by(Entity.embedding.cosine_distance(question_embedding))
        .limit(8)
    )
    result = await db.execute(vector_query)
    vector_results = result.all()

    # Filter by minimum similarity threshold
    for entity, similarity in vector_results:
        if similarity > 0.3:  # Only include reasonably relevant entities
            found_entities.append(entity)

    # 2. Keyword fallback for additional matches
    stop_words = {
        "che", "cosa", "come", "quando", "dove", "chi", "quale", "quanto",
        "mi", "ha", "ho", "hai", "hanno", "era", "sono", "stato", "stata",
        "il", "lo", "la", "le", "gli", "un", "una", "del", "della", "di",
        "da", "in", "con", "su", "per", "tra", "fra", "non", "più", "anche",
        "questo", "quello", "sua", "suo", "mio", "mia", "tutti", "tutte",
        "the", "is", "was", "what", "who", "when", "where", "how", "about",
        "ieri", "oggi", "settimana", "scorsa", "scorso", "mese", "ultima",
        "ultimo", "ultimi", "ultime", "giorni", "giorno",
    }

    words = [w.strip("?.,!\"'") for w in question.lower().split()]
    keywords = [w for w in words if len(w) > 2 and w not in stop_words]

    if keywords:
        conditions = [Entity.name.ilike(f"%{kw}%") for kw in keywords]
        from sqlalchemy import or_
        keyword_query = (
            select(Entity)
            .where(Entity.user_id == user_id)
            .where(or_(*conditions))
            .order_by(Entity.created_at.desc())
            .limit(5)
        )
        result = await db.execute(keyword_query)
        keyword_entities = result.scalars().all()

        # Add keyword results not already found by vector search
        found_ids = {e.id for e in found_entities}
        for e in keyword_entities:
            if e.id not in found_ids:
                found_entities.append(e)

    if not found_entities:
        return ""

    # Deduplicate and limit
    found_entities = found_entities[:10]

    # Format entities as structured context
    lines = []
    for e in found_entities:
        line = f"- [{e.entity_type.upper()}] {e.name}"
        if e.content:
            line += f": {e.content}"
        if e.metadata_:
            meta_parts = []
            for key, val in e.metadata_.items():
                if val and key not in ("tags",):
                    meta_parts.append(f"{key}={val}")
            if meta_parts:
                line += f" ({', '.join(meta_parts)})"
        lines.append(line)

    return "\n".join(lines)


# Where a word was said: the latest lines first, at most this many
MAX_SAID = 20


async def where_said(db: AsyncSession, user_id: uuid.UUID, words: str) -> str:
    """The transcript lines with `words` exactly (any case), newest first, each with its
    time and conversation: "did anyone say 'fattura'?" is a literal question, which
    the search by meaning can miss."""
    from app.core.timezone import user_zone
    from app.models.segment import Segment
    from app.models.transcription import Transcription

    pattern = "%" + words.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
    rows = (
        await db.execute(
            select(Segment.recorded_at, Conversation.title, Transcription.text)
            .join(Transcription, Transcription.segment_id == Segment.id)
            .outerjoin(Conversation, Conversation.id == Segment.conversation_id)
            .where(Segment.user_id == user_id)
            .where(Transcription.text.ilike(pattern, escape="\\"))
            .order_by(Segment.recorded_at.desc())
            .limit(MAX_SAID)
        )
    ).all()
    return "\n".join(
        f"- {at.astimezone(user_zone()):%Y-%m-%d %H:%M} ({title or 'untitled'}): {text[:300]}"
        for at, title, text in rows
    )
