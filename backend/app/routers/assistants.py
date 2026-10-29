"""Profile → Assistants: templates, and the user's assistants made, edited and deleted
(services/assistants.py)."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.assistant import Assistant
from app.services import assistants
from app.services.assistants import AssistantError
from app.services.language import account_languages

router = APIRouter(prefix="/assistants", tags=["assistants"])


class AssistantOut(BaseModel):
    id: uuid.UUID
    name: str
    emoji: str
    instructions: str
    notes: str
    document_ids: list[str]
    created_at: datetime
    updated_at: datetime


class AssistantsOut(BaseModel):
    assistants: list[AssistantOut]


class TemplateOut(BaseModel):
    key: str
    name: str
    emoji: str
    instructions: str


class AssistantIn(BaseModel):
    # From a template (its name, emoji and instructions), or the fields themselves
    template: str | None = None
    name: str | None = Field(default=None, max_length=200)
    emoji: str | None = Field(default=None, max_length=16)
    instructions: str | None = Field(default=None, max_length=10_000)
    notes: str | None = Field(default=None, max_length=10_000)
    document_ids: list[str] | None = None


def _out(assistant: Assistant) -> AssistantOut:
    return AssistantOut(
        id=assistant.id, name=assistant.name, emoji=assistant.emoji,
        instructions=assistant.instructions, notes=assistant.notes,
        document_ids=list(assistant.document_ids or []),
        created_at=assistant.created_at, updated_at=assistant.updated_at,
    )


def _refused(exc: AssistantError) -> HTTPException:
    return HTTPException(status_code=exc.status, detail=str(exc))


async def _apply(db, user_id, assistant: Assistant, body: AssistantIn) -> None:
    if body.name is not None:
        assistant.name = assistants.check_name(body.name)
    if body.emoji is not None:
        assistant.emoji = body.emoji.strip() or assistants.DEFAULT_EMOJI
    if body.instructions is not None:
        assistant.instructions = assistants.check_text(
            body.instructions, assistants.MAX_INSTRUCTIONS, "Instructions"
        )
    if body.notes is not None:
        assistant.notes = assistants.check_text(body.notes, assistants.MAX_NOTES, "Notes")
    if body.document_ids is not None:
        assistant.document_ids = await assistants.check_documents(db, user_id, body.document_ids)


@router.get("/templates", response_model=list[TemplateOut])
async def list_templates(
    user_id: uuid.UUID = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)
):
    language, _ = await account_languages(db, user_id)
    return [TemplateOut(**t) for t in assistants.templates(language)]


@router.get("", response_model=AssistantsOut)
async def list_assistants(
    user_id: uuid.UUID = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)
):
    rows = await db.scalars(
        select(Assistant).where(Assistant.user_id == user_id).order_by(Assistant.created_at)
    )
    return AssistantsOut(assistants=[_out(a) for a in rows])


@router.post("", response_model=AssistantOut, status_code=status.HTTP_201_CREATED)
async def make_assistant(
    body: AssistantIn,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        await assistants.room_for_one(db, user_id)
        start = {"name": "", "emoji": assistants.DEFAULT_EMOJI, "instructions": ""}
        if body.template is not None:
            language, _ = await account_languages(db, user_id)
            start = assistants.template(body.template, language)
        assistant = Assistant(
            id=uuid.uuid4(), user_id=user_id, name=start["name"], emoji=start["emoji"],
            instructions=start["instructions"], notes="", document_ids=[],
        )
        await _apply(db, user_id, assistant, body)
        assistant.name = assistants.check_name(assistant.name)
    except AssistantError as exc:
        raise _refused(exc) from exc
    db.add(assistant)
    await db.commit()
    await db.refresh(assistant)
    return _out(assistant)


@router.patch("/{assistant_id}", response_model=AssistantOut)
async def edit_assistant(
    assistant_id: uuid.UUID,
    body: AssistantIn,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        assistant = await assistants.owned(db, user_id, assistant_id)
        await _apply(db, user_id, assistant, body)
    except AssistantError as exc:
        raise _refused(exc) from exc
    await db.commit()
    await db.refresh(assistant)
    return _out(assistant)


@router.delete("/{assistant_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_assistant(
    assistant_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Its chats and routines stay, with plain Echo."""
    try:
        assistant = await assistants.owned(db, user_id, assistant_id)
    except AssistantError as exc:
        raise _refused(exc) from exc
    await db.delete(assistant)
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
