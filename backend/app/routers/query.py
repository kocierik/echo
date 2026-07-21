"""Query API: natural language search over personal memory with RAG."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends
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


class QueryRequest(BaseModel):
    question: str
    top_k: int = 5
    date_from: datetime | None = None
    date_to: datetime | None = None


class SourceChunk(BaseModel):
    conversation_id: uuid.UUID
    text: str
    similarity: float

    model_config = {"from_attributes": True}


class QueryResponse(BaseModel):
    answer: str
    sources: list[SourceChunk]
    date_filter: dict | None = None


@router.post("", response_model=QueryResponse)
async def query_memory(
    request: QueryRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Query the user's memory using natural language.

    Performs RAG with optional temporal filtering:
    1. Extract date range from question (or use explicit date_from/date_to)
    2. Embed the question
    3. Find similar chunks via pgvector (filtered by date if applicable)
    4. Find relevant entities
    5. Assemble context and generate answer with LLM
    """
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

    # 4. Find relevant entities
    entities_context = await find_relevant_entities(db, user_id, request.question)

    if not rows and not entities_context:
        no_result_msg = "Non ho ancora informazioni nella memoria per rispondere a questa domanda."
        if date_range:
            no_result_msg = (
                "Non ho trovato informazioni nella memoria per il periodo indicato. "
                "Prova a riformulare la domanda o a estendere il periodo."
            )
        return QueryResponse(
            answer=no_result_msg,
            sources=[],
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

    # 6. Generate answer via LLM
    llm_service = get_llm_query_service()

    system_prompt = (
        "Sei un assistente personale. L'utente ti fa domande sulla sua memoria — "
        "conversazioni, idee, task, persone menzionate in passato. "
        "Rispondi basandoti SOLO sul contesto fornito. "
        "Il contesto include 'Conoscenze strutturate' (entità estratte) e "
        "frammenti di trascrizioni reali. "
        "Se il contesto non contiene informazioni sufficienti, dillo chiaramente. "
        "Rispondi in italiano."
    )

    if date_range:
        system_prompt += (
            f"\n\nNota: i risultati sono filtrati per il periodo "
            f"{date_range.date_from.strftime('%d/%m/%Y')} - "
            f"{date_range.date_to.strftime('%d/%m/%Y')}."
        )

    messages = [
        LLMMessage(role="system", content=system_prompt),
        LLMMessage(
            role="user",
            content=f"Contesto dalla memoria:\n\n{context}\n\n---\n\nDomanda: {request.question}",
        ),
    ]
    response = await llm_service.complete(messages, temperature=0.3)

    return QueryResponse(
        answer=response.content,
        sources=sources,
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
    db: AsyncSession, user_id: uuid.UUID, question: str
) -> str:
    """Find entities relevant to the question using keyword matching.

    Searches entity names against words in the question.
    Returns a formatted string with entity info, or empty string if none found.
    """
    # Extract significant words from question (skip short/common words)
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

    if not keywords:
        return ""

    # Search entities whose name matches any keyword
    conditions = [Entity.name.ilike(f"%{kw}%") for kw in keywords]

    from sqlalchemy import or_
    query = (
        select(Entity)
        .where(Entity.user_id == user_id)
        .where(or_(*conditions))
        .order_by(Entity.created_at.desc())
        .limit(10)
    )

    result = await db.execute(query)
    entities = result.scalars().all()

    if not entities:
        return ""

    # Format entities as structured context
    lines = []
    for e in entities:
        line = f"- [{e.entity_type.upper()}] {e.name}"
        if e.content:
            line += f": {e.content}"
        if e.metadata_:
            # Add relevant metadata
            meta_parts = []
            for key, val in e.metadata_.items():
                if val and key not in ("tags",):
                    meta_parts.append(f"{key}={val}")
            if meta_parts:
                line += f" ({', '.join(meta_parts)})"
        lines.append(line)

    return "\n".join(lines)
