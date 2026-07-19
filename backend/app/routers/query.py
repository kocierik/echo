"""Query API: natural language search over personal memory with RAG."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.chunk import Chunk
from app.models.entity import Entity
from app.services.embedding_openai import get_embedding_service
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_query_service

router = APIRouter(prefix="/query", tags=["query"])


class QueryRequest(BaseModel):
    question: str
    top_k: int = 5


class SourceChunk(BaseModel):
    conversation_id: uuid.UUID
    text: str
    similarity: float

    model_config = {"from_attributes": True}


class QueryResponse(BaseModel):
    answer: str
    sources: list[SourceChunk]


@router.post("", response_model=QueryResponse)
async def query_memory(
    request: QueryRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Query the user's memory using natural language.

    Performs RAG:
    1. Embed the question
    2. Find similar chunks via pgvector
    3. Find relevant entities by name match
    4. Assemble context (chunks + entities)
    5. Generate answer with LLM
    """
    # 1. Embed the question
    embedding_service = get_embedding_service()
    question_embedding = await embedding_service.embed(request.question)

    # 2. Find similar chunks via pgvector cosine similarity
    similarity_query = (
        select(
            Chunk.conversation_id,
            Chunk.text,
            (1 - Chunk.embedding.cosine_distance(question_embedding)).label("similarity"),
        )
        .join(Chunk.conversation)
        .where(text("conversations.user_id = :user_id"))
        .params(user_id=user_id)
        .where(Chunk.embedding.isnot(None))
        .order_by(Chunk.embedding.cosine_distance(question_embedding))
        .limit(request.top_k)
    )

    result = await db.execute(similarity_query)
    rows = result.all()

    # 3. Find relevant entities
    # Extract keywords from the question for entity name matching
    entities_context = await find_relevant_entities(db, user_id, request.question)

    if not rows and not entities_context:
        return QueryResponse(
            answer="Non ho ancora informazioni nella memoria per rispondere a questa domanda.",
            sources=[],
        )

    # 4. Build context from chunks + entities
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

    # 5. Generate answer via LLM
    llm_service = get_llm_query_service()
    messages = [
        LLMMessage(
            role="system",
            content=(
                "Sei un assistente personale. L'utente ti fa domande sulla sua memoria — "
                "conversazioni, idee, task, persone menzionate in passato. "
                "Rispondi basandoti SOLO sul contesto fornito. "
                "Il contesto include 'Conoscenze strutturate' (entità estratte) e "
                "frammenti di trascrizioni reali. "
                "Se il contesto non contiene informazioni sufficienti, dillo chiaramente. "
                "Rispondi in italiano."
            ),
        ),
        LLMMessage(
            role="user",
            content=f"Contesto dalla memoria:\n\n{context}\n\n---\n\nDomanda: {request.question}",
        ),
    ]
    response = await llm_service.complete(messages, temperature=0.3)

    return QueryResponse(answer=response.content, sources=sources)


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
