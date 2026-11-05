"""Documents (Profile → Memory → Documents): the user uploads a file; the worker
(workers/documents.py) reads its text, splits it into passages and embeds them, so memory
answers can quote it (services/memory_retrieval.py). The file is held only until it is
read, then dropped: Echo keeps the text, never the file.

The upload only checks what is cheap (size, kind, the file's first bytes, how many
documents); reading happens in the worker, off the API's event loop, within limits: a file
whose text cannot be read (a scanned PDF, a password, a zip that opens huge, bytes that
are not text) ends failed with the reason.
"""

import codecs
import io
import logging
import uuid
import zipfile

from docx import Document as WordDocument
from docx.oxml.ns import qn
from pypdf import PdfReader
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.document import Document
from app.services.chunking import chunk_text

logger = logging.getLogger(__name__)

MAX_BYTES = 10 * 1024 * 1024
MAX_DOCUMENTS = 30
KINDS = {".pdf": "pdf", ".docx": "docx", ".txt": "txt", ".md": "md", ".markdown": "md"}

# Reading limits: a 10 MB file can still open into far more
MAX_PAGES = 2000
MAX_UNZIPPED = 50 * 1024 * 1024
MAX_ZIP_ENTRIES = 2000
# About 300,000 words: past this a document is too long to search well
MAX_CHARS = 2_000_000
_TOO_MUCH_TEXT = "Too much text in it: at most about 300,000 words"
# More than this share of control characters: binary, not text
MAX_CONTROL_SHARE = 0.05

# Passages: sentence-aware, then cut short. A long passage mixes many subjects, so a
# question about one of them (where you studied, in your CV) is too far from all of it
PASSAGE_TARGET = 120
PASSAGE_OVERLAP = 20
PASSAGE_WORDS = 160
PASSAGE_CHARS = 1200


class DocumentError(Exception):
    """The document is refused, or cannot be read: `status` is the HTTP status (upload)."""

    def __init__(self, message: str, status: int = 422):
        super().__init__(message)
        self.status = status


def kind_of(filename: str, data: bytes) -> str:
    """The kind by the name, checked against the file's first bytes."""
    name = filename.lower()
    kind = next((k for extension, k in KINDS.items() if name.endswith(extension)), None)
    if kind is None:
        raise DocumentError("Only PDF, Word, text or Markdown files can be added")
    if kind == "pdf" and not data.startswith(b"%PDF"):
        raise DocumentError("This file is not a PDF")
    if kind == "docx" and not data.startswith(b"PK"):
        raise DocumentError("This file is not a Word document")
    return kind


async def add_document(
    db: AsyncSession, user_id: uuid.UUID, filename: str, data: bytes
) -> Document:
    """The document, waiting for the worker to read it (the caller commits)."""
    if len(data) > MAX_BYTES:
        raise DocumentError("At most 10 MB per document", 413)
    kind = kind_of(filename, data)
    count = await db.scalar(
        select(func.count()).select_from(Document).where(Document.user_id == user_id)
    )
    if (count or 0) >= MAX_DOCUMENTS:
        raise DocumentError(f"At most {MAX_DOCUMENTS} documents: delete one first", 409)
    document = Document(
        id=uuid.uuid4(),
        user_id=user_id,
        title=(filename.strip() or "Document")[:255],
        kind=kind,
        size_bytes=len(data),
        status="processing",
        text="",
        word_count=0,
        raw=data,
    )
    db.add(document)
    await db.flush()
    return document


def _pdf_text(data: bytes) -> tuple[str, int]:
    try:
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted:
            # Many statements and forms have only an owner password: readable as they are
            # 0: NOT_DECRYPTED (pypdf's PasswordType, not exported in its public API)
            if reader.decrypt("") == 0:
                raise DocumentError("This PDF is protected by a password")
        if len(reader.pages) > MAX_PAGES:
            raise DocumentError(f"Too many pages: at most {MAX_PAGES}")
        pages = []
        read = 0
        for page in reader.pages:
            pages.append(page.extract_text() or "")
            read += len(pages[-1])
            # Stopped as soon as it is too much, not after every page is read
            if read > MAX_CHARS:
                raise DocumentError(_TOO_MUCH_TEXT)
    except DocumentError:
        raise
    except Exception as exc:
        # Malformed files raise anything: a parse error, a decompression guard, a type error
        raise DocumentError("This PDF cannot be read") from exc
    return "\n\n".join(page.strip() for page in pages if page.strip()), len(pages)


def _cell_text(tc) -> str:
    return "\n".join(
        "".join(t.text or "" for t in p.iter(qn("w:t"))) for p in tc.iter(qn("w:p"))
    )


def _docx_text(data: bytes) -> str:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ZIP_ENTRIES or sum(e.file_size for e in entries) > MAX_UNZIPPED:
                raise DocumentError("This Word document is too large once opened")
        word = WordDocument(io.BytesIO(data))
        parts = [p.text for p in word.paragraphs]
        read = sum(len(part) for part in parts)
        for table in word.tables:
            # The cells as written: python-docx's row.cells repeats a merged cell in every
            # row and column it spans, so one merged cell could multiply the text
            for tr in table._tbl.tr_lst:
                parts.append(" | ".join(
                    _cell_text(tc) for tc in tr.tc_lst if tc.vMerge != "continue"
                ))
                read += len(parts[-1])
                if read > MAX_CHARS:
                    raise DocumentError(_TOO_MUCH_TEXT)
    except DocumentError:
        raise
    except Exception as exc:
        raise DocumentError("This Word document cannot be read") from exc
    return "\n".join(part for part in parts if part.strip())


def _plain_text(data: bytes) -> str:
    for bom, encoding in (
        (codecs.BOM_UTF8, "utf-8-sig"),
        (codecs.BOM_UTF16_LE, "utf-16"),
        (codecs.BOM_UTF16_BE, "utf-16"),
    ):
        if data.startswith(bom):
            return data.decode(encoding, errors="replace")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def extract_text(kind: str, data: bytes) -> tuple[str, int | None]:
    """The text and, for a PDF, its pages; CPU work, run off the event loop."""
    pages: int | None = None
    if kind == "pdf":
        text, pages = _pdf_text(data)
    elif kind == "docx":
        text = _docx_text(data)
    else:
        text = _plain_text(data)
        control = sum(1 for c in text if ord(c) < 32 and c not in "\n\r\t")
        if text and control / len(text) > MAX_CONTROL_SHARE:
            raise DocumentError("This file is not text")
    # The database refuses NUL characters
    text = text.replace("\x00", "").strip()
    if not text:
        raise DocumentError(
            "No text found in it: a scanned PDF needs a photo of each page instead"
            if kind == "pdf"
            else "No text found in it"
        )
    if len(text) > MAX_CHARS:
        raise DocumentError(_TOO_MUCH_TEXT)
    return text, pages


def passages(text: str) -> list[str]:
    """Sentence-aware passages, each at most PASSAGE_WORDS words and PASSAGE_CHARS
    characters: tables, statements and text without full stops are cut too."""
    out: list[str] = []
    for chunk in chunk_text(text, PASSAGE_TARGET, PASSAGE_OVERLAP) or [text]:
        words = chunk.split()
        for start in range(0, len(words), PASSAGE_WORDS):
            piece = " ".join(words[start : start + PASSAGE_WORDS])
            out += [piece[i : i + PASSAGE_CHARS] for i in range(0, len(piece), PASSAGE_CHARS)]
    return [p for p in out if p.strip()]


def searchable(title: str, passage: str) -> str:
    """What is embedded for a passage: under its document's name, so "my CV" finds the
    passages of main-cv.pdf. The passage alone is kept and quoted."""
    return f"From the document {title}:\n{passage}"
