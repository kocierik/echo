"""Memory retrieval: question -> RAG context string + sources (no LLM call).

Shared by POST /api/query, the action agent's search_memory tool and the voice worker.
"""

import uuid
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.chunk import Chunk
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.services.temporal import DateRange, conversation_overlaps


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
) -> MemoryContext:
    """Embed the question, search chunks/entities/summaries and assemble the context.

    date_range is used as given (the caller resolves explicit filters or NLP extraction).
    embedding_service defaults to the configured one; callers may inject their own.
    """
    if embedding_service is None:
        from app.services.embedding_openai import get_embedding_service

        embedding_service = get_embedding_service()
    question_embedding = await embedding_service.embed(question)

    similarity_query = (
        select(
            Chunk.id,
            Chunk.conversation_id,
            Chunk.text,
            (1 - Chunk.embedding.cosine_distance(question_embedding)).label("similarity"),
            Conversation.title.label("conversation_title"),
            Conversation.started_at.label("conversation_started_at"),
        )
        .join(Conversation, Conversation.id == Chunk.conversation_id)
        .where(Conversation.user_id == user_id)
        .where(Chunk.embedding.isnot(None))
    )

    # Conversations that overlap the period (not only those starting in it)
    if date_range:
        similarity_query = similarity_query.where(
            *conversation_overlaps(date_range.date_from, date_range.date_to)
        )

    similarity_query = similarity_query.order_by(
        Chunk.embedding.cosine_distance(question_embedding)
    ).limit(top_k)

    result = await db.execute(similarity_query)
    rows = result.all()

    # Apply feedback re-ranking
    from app.routers.feedback import get_chunk_feedback_scores

    if rows:
        chunk_ids = [row.id for row in rows]
        feedback_multipliers = await get_chunk_feedback_scores(db, user_id, chunk_ids)

        reranked = []
        for row in rows:
            multiplier = feedback_multipliers.get(row.id, 1.0)
            if multiplier == 0.0:
                continue  # Excluded by negative feedback
            reranked.append((row, float(row.similarity) * multiplier))

        reranked.sort(key=lambda x: x[1], reverse=True)
        rows = [r[0] for r in reranked]

    # Relevant entities (vector + keyword search)
    entities_context = await find_relevant_entities(db, user_id, question, question_embedding)

    # Conversation summaries for matched conversations (high-level context)
    conversation_summaries = ""
    if rows:
        matched_conv_ids = list({row.conversation_id for row in rows})
        summaries_query = (
            select(Conversation.title, Conversation.summary, Conversation.started_at)
            .where(Conversation.id.in_(matched_conv_ids))
            .where(Conversation.summary.isnot(None))
            .where(Conversation.summary != "")  # "" = too short to summarize
            .order_by(Conversation.started_at.desc())
        )
        summaries_result = await db.execute(summaries_query)
        summaries_rows = summaries_result.all()
        if summaries_rows:
            summary_lines = []
            for s in summaries_rows:
                date_str = s.started_at.strftime("%d/%m/%Y %H:%M")
                title = s.title or "Conversation"
                summary_lines.append(f"- [{date_str}] {title}: {s.summary}")
            conversation_summaries = "\n".join(summary_lines)

    if not rows and not entities_context:
        return MemoryContext(context="", sources=[], date_range=date_range)

    context_parts = []
    sources = []

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
