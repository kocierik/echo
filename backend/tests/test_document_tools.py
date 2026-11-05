"""Reading a document whole: the agent's prompt lists the documents it may read (an
assistant's own when it has some), and the tool reads one by its name, a slice at a time."""

import uuid

from app.actions import document_tools
from app.actions.document_tools import documents_prompt, run_document_tool
from app.models.document import Document
from tests.conftest import TEST_USER_ID


async def _document(db, title, text, user_id=TEST_USER_ID, status="ready"):
    document = Document(
        id=uuid.uuid4(), user_id=user_id, title=title, kind="pdf", size_bytes=1,
        status=status, text=text, word_count=len(text.split()),
    )
    db.add(document)
    await db.commit()
    return document


async def test_the_prompt_lists_an_assistants_documents_or_all(db_session):
    payslip = await _document(db_session, "bulletin-de-paie-10-2026.pdf", "Net à payer 2282,92")
    await _document(db_session, "main-cv.pdf", "DevOps engineer")
    await _document(db_session, "other.pdf", "x", user_id=uuid.uuid4())
    await _document(db_session, "reading.pdf", "x", status="processing")

    theirs = await documents_prompt(db_session, TEST_USER_ID)
    its = await documents_prompt(db_session, TEST_USER_ID, [str(payslip.id)])

    assert "main-cv.pdf" in theirs and "bulletin-de-paie" in theirs
    assert "other.pdf" not in theirs and "reading.pdf" not in theirs
    assert "bulletin-de-paie" in its and "main-cv.pdf" not in its
    assert "this assistant's documents" in its


async def test_a_document_is_read_by_part_of_its_name(db_session):
    await _document(db_session, "bulletin-de-paie-10-2026.pdf", "Net à payer 2282,92 €")

    result = await run_document_tool(db_session, TEST_USER_ID, {"document": "bulletin"}, None)

    assert result.ok
    assert result.data["document"] == "bulletin-de-paie-10-2026.pdf"
    assert "2282,92" in result.data["text"]
    assert "next_offset" not in result.data


async def test_a_long_one_comes_a_slice_at_a_time(db_session, monkeypatch):
    monkeypatch.setattr(document_tools, "SLICE", 10)
    await _document(db_session, "lungo.txt", "abcdefghij" * 3)

    first = await run_document_tool(db_session, TEST_USER_ID, {"document": "lungo"}, None)
    last = await run_document_tool(
        db_session, TEST_USER_ID, {"document": "lungo", "offset": 20}, None
    )

    assert (first.data["text"], first.data["next_offset"]) == ("abcdefghij", 10)
    assert last.data["characters"] == 30 and "next_offset" not in last.data


async def test_an_assistant_reads_only_its_own(db_session):
    payslip = await _document(db_session, "busta-paga.pdf", "netto")
    await _document(db_session, "main-cv.pdf", "DevOps")

    result = await run_document_tool(
        db_session, TEST_USER_ID, {"document": "main-cv"}, [str(payslip.id)]
    )

    assert result.ok is False and "listed name" in result.error
