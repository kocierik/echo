"""Query feedback API: rate RAG responses to improve future results."""

import uuid

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.query_feedback import QueryFeedback

router = APIRouter(prefix="/query/feedback", tags=["feedback"])


class FeedbackRequest(BaseModel):
    session_id: str
    message_index: int
    rating: str  # "positive" | "negative"
    comment: str | None = None
    source_chunk_ids: list[str] = []


class FeedbackResponse(BaseModel):
    id: uuid.UUID
    rating: str
    message: str


@router.post("", response_model=FeedbackResponse, status_code=201)
async def submit_feedback(
    request: FeedbackRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Submit feedback on a RAG response (positive or negative).

    This data is used to re-rank chunks in future queries:
    - Positive feedback boosts the source chunks' relevance
    - Negative feedback penalizes them (3+ negatives = excluded)
    """
    if request.rating not in ("positive", "negative"):
        raise HTTPException(status_code=400, detail="Rating must be 'positive' or 'negative'")

    feedback = QueryFeedback(
        user_id=user_id,
        session_id=uuid.UUID(request.session_id),
        message_index=request.message_index,
        rating=request.rating,
        comment=request.comment,
        source_chunk_ids=request.source_chunk_ids,
    )
    db.add(feedback)

    return FeedbackResponse(
        id=feedback.id,
        rating=feedback.rating,
        message="Feedback registrato. Grazie!",
    )


async def get_chunk_feedback_scores(
    db: AsyncSession, user_id: uuid.UUID, chunk_ids: list[uuid.UUID]
) -> dict[uuid.UUID, float]:
    """Get feedback-based multipliers for a set of chunk IDs.

    Returns a dict of chunk_id → multiplier:
    - 1.0 = no feedback
    - > 1.0 = positive feedback (boost)
    - < 1.0 = negative feedback (penalty)
    - 0.0 = excluded (3+ net negative)
    """
    if not chunk_ids:
        return {}

    chunk_id_strs = [str(cid) for cid in chunk_ids]

    # Fetch all feedback that references these chunks
    query = (
        select(QueryFeedback)
        .where(QueryFeedback.user_id == user_id)
    )
    result = await db.execute(query)
    all_feedback = result.scalars().all()

    # Count net scores per chunk
    scores: dict[str, int] = {cid: 0 for cid in chunk_id_strs}

    for fb in all_feedback:
        for cid in fb.source_chunk_ids:
            if cid in scores:
                if fb.rating == "positive":
                    scores[cid] += 1
                else:
                    scores[cid] -= 1

    # Convert to multipliers
    multipliers: dict[uuid.UUID, float] = {}
    for cid_str, net_score in scores.items():
        cid = uuid.UUID(cid_str)
        if net_score <= -3:
            multipliers[cid] = 0.0  # Exclude
        elif net_score < 0:
            multipliers[cid] = 0.9 ** abs(net_score)  # Compound penalty
        elif net_score > 0:
            multipliers[cid] = 1.0 + (0.05 * net_score)  # Compound boost
        else:
            multipliers[cid] = 1.0

    return multipliers
