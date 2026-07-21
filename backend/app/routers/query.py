"""Query API: natural language search over personal memory with RAG."""

import json
import uuid
from datetime import datetime

import redis.asyncio as aioredis
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.chunk import Chunk
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.services.embedding_openai import get_embedding_service
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_query_service
from app.services.temporal import DateRange, extract_date_range

router = APIRouter(prefix="/query", tags=["query"])

# Session TTL: 30 minutes of inactivity
SESSION_TTL_SECONDS = 30 * 60
# Max history messages to keep (to avoid token explosion)
MAX_HISTORY_MESSAGES = 20


class QueryRequest(BaseModel):
    question: str
    top_k: int = 5
    date_from: datetime | None = None
    date_to: datetime | None = None
    session_id: str | None = None


class SourceChunk(BaseModel):
    conversation_id: uuid.UUID
    text: str
    similarity: float

    model_config = {"from_attributes": True}


class QueryResponse(BaseModel):
    answer: str
    sources: list[SourceChunk]
    session_id: str
    date_filter: dict | None = None


async def _get_session_history(
    redis_client: aioredis.Redis, session_id: str
) -> list[dict]:
    """Retrieve conversation history from Redis."""
    raw = await redis_client.get(f"session:{session_id}")
    if raw is None:
        return []
    return json.loads(raw)


async def _save_session_history(
    redis_client: aioredis.Redis, session_id: str, history: list[dict]
):
    """Save conversation history to Redis with TTL refresh."""
    # Trim to max history
    if len(history) > MAX_HISTORY_MESSAGES:
        history = history[-MAX_HISTORY_MESSAGES:]
    await redis_client.set(
        f"session:{session_id}",
        json.dumps(history),
        ex=SESSION_TTL_SECONDS,
    )


@router.post("", response_model=QueryResponse)
async def query_memory(
    http_request: Request,
    request: QueryRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Query the user's memory using natural language.

    Supports multi-turn follow-up via session_id:
    - First request: omit session_id → a new session is created
    - Follow-up: include session_id from previous response → continues the conversation

    Performs RAG with optional temporal filtering:
    1. Extract date range from question (or use explicit date_from/date_to)
    2. Embed the question
    3. Find similar chunks via pgvector (filtered by date if applicable)
    4. Find relevant entities
    5. Assemble context + history and generate answer with LLM
    """
    redis_client = http_request.app.state.redis

    # Resolve or create session
    session_id = request.session_id or str(uuid.uuid4())
    history = await _get_session_history(redis_client, session_id)

    # 1. Determine date filter: explicit params take priority, then NLP extraction
    date_range = None
    if request.date_from or request.date_to:
        date_range = DateRange(
            date_from=request.date_from,
            date_to=request.date_to or datetime.max,
        )
    else:
        date_range = extract_date_range(request.question)

    # 2. Embed the question
    embedding_service = get_embedding_service()
    question_embedding = await embedding_service.embed(request.question)

    # 3. Find similar chunks via pgvector cosine similarity (with date filter)
    similarity_query = (
        select(
            Chunk.conversation_id,
            Chunk.text,
            (1 - Chunk.embedding.cosine_distance(question_embedding)).label("similarity"),
        )
        .join(Conversation, Conversation.id == Chunk.conversation_id)
        .where(Conversation.user_id == user_id)
        .where(Chunk.embedding.isnot(None))
    )

    # Apply temporal filter
    if date_range:
        if date_range.date_from:
            similarity_query = similarity_query.where(
                Conversation.started_at >= date_range.date_from
            )
        if date_range.date_to:
            similarity_query = similarity_query.where(
                Conversation.started_at <= date_range.date_to
            )

    similarity_query = (
        similarity_query
        .order_by(Chunk.embedding.cosine_distance(question_embedding))
        .limit(request.top_k)
    )

    result = await db.execute(similarity_query)
    rows = result.all()

    # 4. Find relevant entities (vector + keyword search)
    entities_context = await find_relevant_entities(
        db, user_id, request.question, question_embedding
    )

    if not rows and not entities_context:
        no_result_msg = "Non ho ancora informazioni nella memoria per rispondere a questa domanda."
        if date_range:
            no_result_msg = (
                "Non ho trovato informazioni nella memoria per il periodo indicato. "
                "Prova a riformulare la domanda o a estendere il periodo."
            )
        # Save to history even for empty results
        history.append({"role": "user", "content": request.question})
        history.append({"role": "assistant", "content": no_result_msg})
        await _save_session_history(redis_client, session_id, history)

        return QueryResponse(
            answer=no_result_msg,
            sources=[],
            session_id=session_id,
            date_filter=_format_date_filter(date_range),
        )

    # 5. Build context from chunks + entities
    context_parts = []
    sources = []

    # Add entity context first (structured knowledge)
    if entities_context:
        context_parts.append(f"Conoscenze strutturate:\n{entities_context}")

    # Add chunk context (raw transcriptions)
    for row in rows:
        context_parts.append(row.text)
        sources.append(
            SourceChunk(
                conversation_id=row.conversation_id,
                text=row.text[:200],
                similarity=round(float(row.similarity), 4),
            )
        )

    context = "\n\n---\n\n".join(context_parts)

    # 6. Generate answer via LLM (with conversation history)
    llm_service = get_llm_query_service()

    system_prompt = (
        "Sei un assistente personale. L'utente ti fa domande sulla sua memoria — "
        "conversazioni, idee, task, persone menzionate in passato. "
        "Rispondi basandoti SOLO sul contesto fornito. "
        "Il contesto include 'Conoscenze strutturate' (entità estratte) e "
        "frammenti di trascrizioni reali. "
        "Se il contesto non contiene informazioni sufficienti, dillo chiaramente. "
        "Se l'utente fa una domanda di follow-up, usa la conversazione precedente "
        "per capire a cosa si riferisce. "
        "Rispondi in italiano."
    )

    if date_range:
        system_prompt += (
            f"\n\nNota: i risultati sono filtrati per il periodo "
            f"{date_range.date_from.strftime('%d/%m/%Y')} - "
            f"{date_range.date_to.strftime('%d/%m/%Y')}."
        )

    messages = [LLMMessage(role="system", content=system_prompt)]

    # Add conversation history for multi-turn context
    for msg in history:
        messages.append(LLMMessage(role=msg["role"], content=msg["content"]))

    # Add current question with fresh RAG context
    user_message = f"Contesto dalla memoria:\n\n{context}\n\n---\n\nDomanda: {request.question}"
    messages.append(LLMMessage(role="user", content=user_message))

    response = await llm_service.complete(messages, temperature=0.3)

    # Save to session history (store clean question, not the RAG-augmented one)
    history.append({"role": "user", "content": request.question})
    history.append({"role": "assistant", "content": response.content})
    await _save_session_history(redis_client, session_id, history)

    return QueryResponse(
        answer=response.content,
        sources=sources,
        session_id=session_id,
        date_filter=_format_date_filter(date_range),
    )


def _format_date_filter(date_range: DateRange | None) -> dict | None:
    """Format date range for API response."""
    if date_range is None:
        return None
    return {
        "from": date_range.date_from.isoformat(),
        "to": date_range.date_to.isoformat(),
    }


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
