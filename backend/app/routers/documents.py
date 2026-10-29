"""Profile → Memory → Documents: add a file (its text is kept, never the file), list,
look at and delete documents (services/documents.py)."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Response, UploadFile, status
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import defer

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.document import Document
from app.services import documents
from app.services.documents import DocumentError

router = APIRouter(prefix="/documents", tags=["documents"])

PREVIEW_CHARS = 600


class DocumentOut(BaseModel):
    id: uuid.UUID
    title: str
    # "pdf" | "docx" | "txt" | "md"
    kind: str
    size_bytes: int
    # "processing" | "ready" | "failed"
    status: str
    error: str | None = None
    pages: int | None = None
    word_count: int
    created_at: datetime


class DocumentDetail(DocumentOut):
    # The beginning of its text
    preview: str


class DocumentsOut(BaseModel):
    documents: list[DocumentOut]


def _out(document: Document) -> dict:
    return {
        "id": document.id, "title": document.title, "kind": document.kind,
        "size_bytes": document.size_bytes, "status": document.status,
        "error": document.error, "pages": document.pages,
        "word_count": document.word_count, "created_at": document.created_at,
    }


async def _owned(db: AsyncSession, user_id: uuid.UUID, document_id: uuid.UUID) -> Document:
    # Never the whole text (up to 2 MB) nor the file just to check who owns it
    document = await db.get(Document, document_id, options=[defer(Document.text)])
    if document is None or document.user_id != user_id:
        raise HTTPException(status_code=404, detail="Document not found")
    return document


@router.get("", response_model=DocumentsOut)
async def list_documents(
    user_id: uuid.UUID = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)
):
    # The list is polled while a document is read: never the texts
    rows = await db.scalars(
        select(Document)
        .options(defer(Document.text))
        .where(Document.user_id == user_id)
        .order_by(Document.created_at.desc())
    )
    return DocumentsOut(documents=[DocumentOut(**_out(d)) for d in rows])


@router.post("", response_model=DocumentOut, status_code=status.HTTP_201_CREATED)
async def add_document(
    file: UploadFile,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    # One byte past the limit is enough to refuse it
    data = await file.read(documents.MAX_BYTES + 1)
    try:
        document = await documents.add_document(db, user_id, file.filename or "", data)
    except DocumentError as exc:
        raise HTTPException(status_code=exc.status, detail=str(exc)) from exc
    await db.commit()
    return DocumentOut(**_out(document))


@router.get("/{document_id}", response_model=DocumentDetail)
async def read_document(
    document_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    document = await _owned(db, user_id, document_id)
    preview = await db.scalar(
        select(func.left(Document.text, PREVIEW_CHARS)).where(Document.id == document_id)
    )
    return DocumentDetail(**_out(document), preview=preview or "")


@router.delete("/{document_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_document(
    document_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The document and its passages: the memory no longer finds it."""
    await db.delete(await _owned(db, user_id, document_id))
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
