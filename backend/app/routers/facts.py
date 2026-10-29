"""Profile → Memory → About you: the facts Echo keeps about the user, and the ones it
suggests from conversations (services/user_facts.py)."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.user_fact import UserFact
from app.services import user_facts
from app.services.user_facts import FactError

router = APIRouter(prefix="/facts", tags=["facts"])


class FactOut(BaseModel):
    id: uuid.UUID
    text: str
    # "kept" | "suggested"
    status: str
    # "you" | "echo" | "conversation"
    source: str
    conversation_id: uuid.UUID | None = None
    created_at: datetime


class FactsOut(BaseModel):
    kept: list[FactOut]
    suggestions: list[FactOut]


class FactIn(BaseModel):
    # Checked again after trimming (services/user_facts.py)
    text: str = Field(max_length=400)


def _out(fact: UserFact) -> FactOut:
    return FactOut(
        id=fact.id, text=fact.text, status=fact.status, source=fact.source,
        conversation_id=fact.conversation_id, created_at=fact.created_at,
    )


def _refused(exc: FactError) -> HTTPException:
    return HTTPException(status_code=exc.status, detail=str(exc))


@router.get("", response_model=FactsOut)
async def list_facts(
    user_id: uuid.UUID = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)
):
    return FactsOut(
        kept=[_out(f) for f in await user_facts.list_facts(db, user_id, "kept")],
        suggestions=[_out(f) for f in await user_facts.list_facts(db, user_id, "suggested")],
    )


@router.post("", response_model=FactOut, status_code=status.HTTP_201_CREATED)
async def add_fact(
    body: FactIn,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        fact = await user_facts.add_kept(db, user_id, body.text, "you")
    except FactError as exc:
        raise _refused(exc) from exc
    await db.commit()
    return _out(fact)


@router.patch("/{fact_id}", response_model=FactOut)
async def edit_fact(
    fact_id: uuid.UUID,
    body: FactIn,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        fact = await user_facts.owned(db, user_id, fact_id)
        fact.text = user_facts.clean(body.text)
    except FactError as exc:
        raise _refused(exc) from exc
    await db.commit()
    return _out(fact)


@router.post("/{fact_id}/keep", response_model=FactOut)
async def keep_fact(
    fact_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        fact = await user_facts.keep(db, user_id, fact_id)
    except FactError as exc:
        raise _refused(exc) from exc
    await db.commit()
    return _out(fact)


@router.delete("/{fact_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_fact(
    fact_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Deletes a kept fact, or discards a suggestion."""
    try:
        fact = await user_facts.owned(db, user_id, fact_id)
    except FactError as exc:
        raise _refused(exc) from exc
    await db.delete(fact)
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
