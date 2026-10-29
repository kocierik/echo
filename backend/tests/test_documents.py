"""Documents (Profile → Memory → Documents): the text of an uploaded file, never the file,
indexed by the worker into chunks the memory searches."""

import io
import uuid

import pytest
from docx import Document as WordDocument
from pypdf import PdfWriter
from sqlalchemy import select

from app.models.document import Document, DocumentChunk
from app.services import documents
from app.workers.documents import index_waiting_documents
from tests.conftest import TEST_USER_ID, test_session


class _Embeddings:
    def __init__(self, fail=False):
        self.fail = fail
        self.batches: list[list[str]] = []

    async def embed(self, text):
        return [0.1] * 1536

    async def embed_batch(self, texts):
        if self.fail:
            raise RuntimeError("embeddings down")
        self.batches.append(texts)
        return [[0.1] * 1536 for _ in texts]


def _docx(*paragraphs: str) -> bytes:
    document = WordDocument()
    for paragraph in paragraphs:
        document.add_paragraph(paragraph)
    out = io.BytesIO()
    document.save(out)
    return out.getvalue()


def _blank_pdf() -> bytes:
    writer = PdfWriter()
    writer.add_blank_page(width=200, height=200)
    out = io.BytesIO()
    writer.write(out)
    return out.getvalue()


async def _upload(client, auth_headers, name, data, content_type="application/octet-stream"):
    return await client.post(
        "/api/documents", headers=auth_headers, files={"file": (name, data, content_type)}
    )


async def test_a_word_file_is_kept_as_text_and_indexed_by_the_worker(client, auth_headers):
    body = _docx("Contratto di affitto.", "Il canone è di 900 euro al mese, da pagare il 5.")

    response = await _upload(client, auth_headers, "Contratto affitto.docx", body)

    assert response.status_code == 201
    created = response.json()
    assert (created["title"], created["kind"], created["status"]) == (
        "Contratto affitto.docx",
        "docx",
        "processing",
    )
    assert created["word_count"] == 15

    embeddings = _Embeddings()
    assert await index_waiting_documents(session_factory=test_session, embeddings=embeddings) == 1

    listed = (await client.get("/api/documents", headers=auth_headers)).json()
    assert [d["status"] for d in listed["documents"]] == ["ready"]
    async with test_session() as db:
        chunks = list(await db.scalars(select(DocumentChunk)))
    assert chunks and "900 euro" in chunks[0].text
    assert chunks[0].user_id == TEST_USER_ID


async def test_a_text_file_and_its_preview(client, auth_headers):
    created = (
        await _upload(client, auth_headers, "note.md", "# Ricette\n\nPasta al pomodoro.".encode())
    ).json()

    detail = (await client.get(f"/api/documents/{created['id']}", headers=auth_headers)).json()

    assert detail["kind"] == "md"
    assert detail["preview"].startswith("# Ricette")


@pytest.mark.parametrize(
    ("name", "data", "message"),
    [
        ("scansione.pdf", _blank_pdf(), "No text"),
        ("vuoto.txt", b"   \n ", "No text"),
        ("programma.exe", b"MZ\x90\x00", "PDF, Word, text or Markdown"),
        ("finto.pdf", b"MZ\x90\x00not a pdf", "not a PDF"),
    ],
)
async def test_what_cannot_be_read_is_refused_with_a_reason(
    client, auth_headers, name, data, message
):
    response = await _upload(client, auth_headers, name, data)

    assert response.status_code == 422
    assert message in response.json()["detail"]
    assert (await client.get("/api/documents", headers=auth_headers)).json()["documents"] == []


async def test_a_file_over_ten_megabytes_is_refused(client, auth_headers):
    response = await _upload(
        client, auth_headers, "grande.txt", b"a " * (documents.MAX_BYTES // 2 + 1)
    )

    assert response.status_code == 413


async def test_past_thirty_documents_one_more_is_refused(client, auth_headers, db_session):
    for i in range(documents.MAX_DOCUMENTS):
        db_session.add(
            Document(
                user_id=TEST_USER_ID,
                title=f"d{i}.txt",
                kind="txt",
                size_bytes=1,
                status="ready",
                text="x",
                word_count=1,
            )
        )
    await db_session.commit()

    response = await _upload(client, auth_headers, "uno.txt", b"uno in piu")

    assert response.status_code == 409


async def test_embeddings_failing_leave_it_failed_with_a_reason(client, auth_headers):
    await _upload(client, auth_headers, "note.txt", b"Il wifi di casa si chiama Rossi-5G.")

    await index_waiting_documents(session_factory=test_session, embeddings=_Embeddings(fail=True))

    [document] = (await client.get("/api/documents", headers=auth_headers)).json()["documents"]
    assert document["status"] == "failed"
    assert document["error"]


async def test_delete_removes_it_and_its_passages(client, auth_headers):
    created = (
        await _upload(client, auth_headers, "note.txt", b"Il codice del cancello 4521.")
    ).json()
    await index_waiting_documents(session_factory=test_session, embeddings=_Embeddings())

    response = await client.delete(f"/api/documents/{created['id']}", headers=auth_headers)

    assert response.status_code == 204
    async with test_session() as db:
        assert list(await db.scalars(select(DocumentChunk))) == []
        assert list(await db.scalars(select(Document))) == []


async def test_someone_elses_document_is_404(client, auth_headers, db_session):
    other = Document(
        user_id=uuid.uuid4(),
        title="x.txt",
        kind="txt",
        size_bytes=1,
        status="ready",
        text="x",
        word_count=1,
    )
    db_session.add(other)
    await db_session.commit()

    assert (await client.get(f"/api/documents/{other.id}", headers=auth_headers)).status_code == 404
    assert (
        await client.delete(f"/api/documents/{other.id}", headers=auth_headers)
    ).status_code == 404
