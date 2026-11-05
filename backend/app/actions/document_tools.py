"""Reading one of the user's documents whole (Profile → Memory → Documents): search_memory
gives only the passages closest to a question, so "summarize my contract" or "what does
the payslip say" found nothing. The agent's prompt lists the documents it may read (an
assistant's own, when it has some) and this tool reads one, a slice at a time.
"""

import logging
import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.provider import ToolResult
from app.models.document import Document

logger = logging.getLogger(__name__)

READ_DOCUMENT = "ECHO_READ_DOCUMENT"
SLICE = 15_000
LISTED = 30

DOCUMENT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": READ_DOCUMENT,
            "description": (
                "Read one of the user's documents listed in the prompt, whole, when the "
                "request is about the document itself (summarize it, what it says, check a "
                "detail, compare it): search_memory gives only pieces. Long documents come "
                f"{SLICE} characters at a time: ask again with next_offset."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "document": {
                        "type": "string",
                        "description": "The document's name as listed, or part of it.",
                    },
                    "offset": {"type": "integer", "description": "From next_offset."},
                },
                "required": ["document"],
            },
        },
    },
]

DOCUMENT_TOOL_NAMES = frozenset({READ_DOCUMENT})


def _scope(user_id: uuid.UUID, document_ids: list[str] | None):
    where = [Document.user_id == user_id, Document.status == "ready"]
    if document_ids:
        where.append(Document.id.in_([uuid.UUID(i) for i in document_ids]))
    return where


async def documents_prompt(
    db: AsyncSession, user_id: uuid.UUID, document_ids: list[str] | None = None
) -> str:
    """The documents the agent may read, for its prompt; "" without any (or unreadable:
    the answer goes on without them)."""
    try:
        rows = (
            await db.execute(
                select(Document.title, Document.word_count)
                .where(*_scope(user_id, document_ids))
                .order_by(Document.created_at.desc())
                .limit(LISTED)
            )
        ).all()
    except Exception:
        logger.warning("Could not list the documents for the agent", exc_info=True)
        return ""
    if not rows:
        return ""
    lines = "\n".join(f"- {row.title} ({row.word_count} words)" for row in rows)
    whose = "this assistant's documents" if document_ids else "the user's documents"
    return (
        f"These are {whose} (files they added). For a question about one of them as a "
        f"whole, read it with {READ_DOCUMENT}; name the document when you use it:\n{lines}"
    )


async def run_document_tool(
    db: AsyncSession, user_id: uuid.UUID, arguments: dict, document_ids: list[str] | None
) -> ToolResult:
    wanted = " ".join(str(arguments.get("document") or "").split())
    if not wanted:
        return ToolResult(ok=False, error="document is required")
    found = (
        await db.execute(
            select(Document.id, Document.title, Document.text)
            .where(*_scope(user_id, document_ids))
            .where(
                (func.lower(Document.title) == wanted.lower())
                | Document.title.ilike(f"%{wanted.replace('%', '').replace('_', ' ')}%")
            )
            .order_by((func.lower(Document.title) == wanted.lower()).desc())
            .limit(1)
        )
    ).first()
    if found is None:
        return ToolResult(ok=False, error=f"No document called {wanted!r}: use a listed name")
    try:
        offset = max(0, int(arguments.get("offset") or 0))
    except (TypeError, ValueError):
        offset = 0
    text = found.text or ""
    piece = text[offset:offset + SLICE]
    end = offset + len(piece)
    return ToolResult(ok=True, data={
        "document": found.title,
        "text": piece,
        "characters": len(text),
        **({"next_offset": end} if end < len(text) else {}),
    })
