"""Documents (Profile → Memory → Documents): the file is held only until the worker has
read it; its text is split, embedded and searched by the memory. What cannot be read ends
failed with the reason; nothing blocks the API or the worker."""

import asyncio
import io
import uuid
import zipfile

import pytest
from docx import Document as WordDocument
from pypdf import PdfWriter
from sqlalchemy import select, text

from app.models.document import Document, DocumentChunk
from app.services import documents
from app.workers.documents import index_waiting_documents
from tests.conftest import TEST_USER_ID, test_session


class _Embeddings:
    def __init__(self, fail=False, gate: asyncio.Event | None = None):
        self.fail = fail
        self.gate = gate
        self.batches: list[list[str]] = []

    async def embed(self, text):
        return [0.1] * 1536

    async def embed_batch(self, texts):
        if self.gate is not None:
            await self.gate.wait()
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


def _pdf(owner_password: str | None = None) -> bytes:
    writer = PdfWriter()
    writer.add_blank_page(width=200, height=200)
    if owner_password:
        writer.encrypt(user_password="", owner_password=owner_password)
    out = io.BytesIO()
    writer.write(out)
    return out.getvalue()


async def _upload(client, auth_headers, name, data):
    return await client.post(
        "/api/documents",
        headers=auth_headers,
        files={"file": (name, data, "application/octet-stream")},
    )


async def _index(embeddings=None):
    while await index_waiting_documents(
        session_factory=test_session, embeddings=embeddings or _Embeddings()
    ):
        pass


async def _only(client, auth_headers):
    [document] = (await client.get("/api/documents", headers=auth_headers)).json()["documents"]
    return document


async def test_a_word_file_is_read_and_indexed_by_the_worker(client, auth_headers):
    body = _docx("Contratto di affitto.", "Il canone è di 900 euro al mese, da pagare il 5.")

    response = await _upload(client, auth_headers, "Contratto affitto.docx", body)

    assert response.status_code == 201
    created = response.json()
    assert (created["title"], created["kind"], created["status"]) == (
        "Contratto affitto.docx",
        "docx",
        "processing",
    )

    await _index()

    document = await _only(client, auth_headers)
    assert (document["status"], document["word_count"]) == ("ready", 15)
    async with test_session() as db:
        chunks = list(await db.scalars(select(DocumentChunk)))
        raw = await db.scalar(text("SELECT raw FROM documents"))
    assert chunks and "900 euro" in chunks[0].text
    assert chunks[0].user_id == TEST_USER_ID
    # The file is gone once read
    assert raw is None


async def test_a_text_file_and_its_preview(client, auth_headers):
    created = (
        await _upload(client, auth_headers, "note.md", "# Ricette\n\nPasta al pomodoro.".encode())
    ).json()
    await _index()

    detail = (await client.get(f"/api/documents/{created['id']}", headers=auth_headers)).json()

    assert detail["kind"] == "md"
    assert detail["preview"].startswith("# Ricette")


async def test_a_utf16_text_file_is_read(client, auth_headers):
    await _upload(client, auth_headers, "note.txt", "Il wifi si chiama Rossi.".encode("utf-16"))
    await _index()

    assert (await _only(client, auth_headers))["word_count"] == 5


async def test_a_pdf_with_only_an_owner_password_is_read(client, auth_headers):
    await _upload(client, auth_headers, "estratto.pdf", _pdf(owner_password="banca"))
    await _index()

    # Readable (a blank page here: no text, so it ends as "no text", not "password")
    document = await _only(client, auth_headers)
    assert "password" not in (document["error"] or "")


@pytest.mark.parametrize(
    ("name", "data", "reason"),
    [
        ("scansione.pdf", _pdf(), "No text"),
        ("vuoto.txt", b"   \n ", "No text"),
        ("binario.txt", bytes(range(256)) * 20, "not text"),
        ("rotto.pdf", b"%PDF-1.7\n" + b"\x00garbage" * 50, "cannot be read"),
    ],
)
async def test_what_cannot_be_read_ends_failed_with_the_reason(
    client, auth_headers, name, data, reason
):
    assert (await _upload(client, auth_headers, name, data)).status_code == 201

    await _index()

    document = await _only(client, auth_headers)
    assert document["status"] == "failed"
    assert reason in document["error"]


async def test_a_word_file_that_opens_huge_is_refused(client, auth_headers):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("word/document.xml", "0" * (60 * 1024 * 1024))
    await _upload(client, auth_headers, "bomba.docx", out.getvalue())

    await _index()

    document = await _only(client, auth_headers)
    assert document["status"] == "failed"
    assert "too large" in document["error"]


async def test_text_without_sentence_ends_is_indexed_in_short_passages(client, auth_headers):
    rows = "\n".join(
        f"riga {i} importo {i * 3} euro data 2026-10-{i % 28 + 1:02d}" for i in range(800)
    )
    await _upload(client, auth_headers, "estratto.txt", rows.encode())

    embeddings = _Embeddings()
    await _index(embeddings)

    assert (await _only(client, auth_headers))["status"] == "ready"
    passages = [p for batch in embeddings.batches for p in batch]
    assert passages and max(len(p.split()) for p in passages) <= documents.PASSAGE_WORDS


@pytest.mark.parametrize(
    ("name", "data", "message"),
    [
        ("programma.exe", b"MZ\x90\x00", "PDF, Word, text or Markdown"),
        ("finto.pdf", b"MZ\x90\x00not a pdf", "not a PDF"),
        ("finto.docx", b"MZ\x90\x00", "not a Word"),
    ],
)
async def test_the_wrong_kind_of_file_is_refused_at_once(client, auth_headers, name, data, message):
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

    await _index(_Embeddings(fail=True))

    document = await _only(client, auth_headers)
    assert document["status"] == "failed"
    assert document["error"]


@pytest.mark.timeout(30)
async def test_a_document_can_be_deleted_while_it_is_indexed(client, auth_headers):
    created = (await _upload(client, auth_headers, "note.txt", b"Il codice 4521.")).json()
    gate = asyncio.Event()
    indexing = asyncio.create_task(
        index_waiting_documents(session_factory=test_session, embeddings=_Embeddings(gate=gate))
    )
    try:
        await asyncio.sleep(0.5)
        # Not held up by the worker waiting on the embeddings
        response = await asyncio.wait_for(
            client.delete(f"/api/documents/{created['id']}", headers=auth_headers), timeout=3
        )
    finally:
        gate.set()
        await indexing

    assert response.status_code == 204
    async with test_session() as db:
        assert list(await db.scalars(select(DocumentChunk))) == []
        assert list(await db.scalars(select(Document))) == []


async def test_delete_removes_it_and_its_passages(client, auth_headers):
    created = (await _upload(client, auth_headers, "note.txt", b"Il codice del cancello.")).json()
    await _index()

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
