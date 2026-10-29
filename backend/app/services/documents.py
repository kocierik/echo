"""Documents (Profile → Memory → Documents): the user uploads a file, Echo keeps its text
(never the file), and the worker (workers/documents.py) splits it into chunks and embeds
them, so memory answers can quote it (services/memory_retrieval.py).

PDF (pypdf), Word .docx (python-docx), text and Markdown; at most 10 MB and 30 documents.
A file whose text cannot be read (a scanned PDF, a password, the wrong type) is refused
with the reason, and nothing is stored.
"""

import io
import logging
import uuid

from docx import Document as WordDocument
from pypdf import PdfReader
from pypdf.errors import PdfReadError
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.document import Document

logger = logging.getLogger(__name__)

MAX_BYTES = 10 * 1024 * 1024
MAX_DOCUMENTS = 30
KINDS = {".pdf": "pdf", ".docx": "docx", ".txt": "txt", ".md": "md", ".markdown": "md"}


class DocumentError(Exception):
    """The document is refused: `status` is the HTTP status that says why."""

    def __init__(self, message: str, status: int = 422):
        super().__init__(message)
        self.status = status


def kind_of(filename: str) -> str:
    name = filename.lower()
    for extension, kind in KINDS.items():
        if name.endswith(extension):
            return kind
    raise DocumentError("Only PDF, Word, text or Markdown files can be added")


def extract_text(kind: str, data: bytes) -> tuple[str, int | None]:
    """The text and, for a PDF, its pages."""
    if kind == "pdf":
        if not data.startswith(b"%PDF"):
            raise DocumentError("This file is not a PDF")
        try:
            reader = PdfReader(io.BytesIO(data))
            if reader.is_encrypted:
                raise DocumentError("This PDF is protected by a password")
            pages = [page.extract_text() or "" for page in reader.pages]
        except (PdfReadError, ValueError, KeyError) as exc:
            raise DocumentError("This PDF cannot be read") from exc
        return "\n\n".join(page.strip() for page in pages if page.strip()), len(pages)
    if kind == "docx":
        if not data.startswith(b"PK"):
            raise DocumentError("This file is not a Word document")
        try:
            word = WordDocument(io.BytesIO(data))
        except Exception as exc:
            raise DocumentError("This Word document cannot be read") from exc
        parts = [p.text for p in word.paragraphs]
        for table in word.tables:
            for row in table.rows:
                parts.append(" | ".join(cell.text for cell in row.cells))
        return "\n".join(part for part in parts if part.strip()), None
    try:
        return data.decode("utf-8"), None
    except UnicodeDecodeError:
        return data.decode("latin-1"), None


async def add_document(
    db: AsyncSession, user_id: uuid.UUID, filename: str, data: bytes
) -> Document:
    """The document, waiting for the worker (the caller commits)."""
    if len(data) > MAX_BYTES:
        raise DocumentError("At most 10 MB per document", 413)
    kind = kind_of(filename)
    count = await db.scalar(
        select(func.count()).select_from(Document).where(Document.user_id == user_id)
    )
    if (count or 0) >= MAX_DOCUMENTS:
        raise DocumentError(f"At most {MAX_DOCUMENTS} documents: delete one first", 409)
    text, pages = extract_text(kind, data)
    text = text.strip()
    if not text:
        raise DocumentError(
            "No text found in it: a scanned PDF needs a photo of each page instead"
            if kind == "pdf"
            else "No text found in it"
        )
    document = Document(
        id=uuid.uuid4(),
        user_id=user_id,
        title=(filename.strip() or "Document")[:255],
        kind=kind,
        size_bytes=len(data),
        status="processing",
        text=text,
        pages=pages,
        word_count=len(text.split()),
    )
    db.add(document)
    await db.flush()
    return document
