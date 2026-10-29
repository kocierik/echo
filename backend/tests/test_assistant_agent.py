"""An assistant's chat: the agent answers as the assistant (its instructions and notes in the
prompt), keeps its notes with a tool, searches only its documents, and its routines carry
it."""

import uuid

from sqlalchemy import select

from app.actions import agent as agent_module
from app.actions.agent import NO_APPS, run_action_agent
from app.models.assistant import Assistant
from app.models.document import Document, DocumentChunk
from app.models.routine import Routine
from app.services import assistants
from app.services.memory_retrieval import MemoryContext, retrieve_memory_context
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService
from tests.test_action_agent import RecordingLLM, _calls, _text

NOTES_TOOL = "ECHO_UPDATE_ASSISTANT_NOTES"


async def _assistant(db, notes="Vegetariano.", document_ids=None):
    assistant = Assistant(
        id=uuid.uuid4(),
        user_id=TEST_USER_ID,
        name="Dieta",
        emoji="🥗",
        instructions="Sei il mio coach per l'alimentazione.",
        notes=notes,
        document_ids=document_ids or [],
    )
    db.add(assistant)
    await db.commit()
    return assistant


async def _run(db, request, llm, assistant=None):
    return await run_action_agent(
        db,
        TEST_USER_ID,
        request,
        [],
        session_id=uuid.uuid4(),
        source="chat",
        provider=NO_APPS,
        llm=llm,
        assistant=assistant,
    )


async def test_the_assistant_answers_with_its_instructions_and_notes(db_session):
    assistant = await _assistant(db_session)
    llm = RecordingLLM([_text("Ok.")])

    await _run(db_session, "cosa mangio stasera?", llm, assistant)

    system = llm.call_log[0][0].content
    assert '"Dieta"' in system
    assert "coach per l'alimentazione" in system
    assert "Vegetariano." in system
    assert NOTES_TOOL in [t["function"]["name"] for t in llm.tools_log[0]]


async def test_plain_echo_has_no_assistant_and_no_notes_tool(db_session):
    llm = RecordingLLM([_text("Ok.")])

    await _run(db_session, "cosa mangio stasera?", llm)

    assert NOTES_TOOL not in [t["function"]["name"] for t in llm.tools_log[0]]
    assert "In this chat you are" not in llm.call_log[0][0].content


async def test_the_assistant_keeps_and_drops_a_note(db_session):
    assistant = await _assistant(db_session, notes="")
    llm = RecordingLLM(
        [
            _calls((NOTES_TOOL, {"action": "add", "line": "Colazione: yogurt e frutta"})),
            _text("Annotato."),
        ]
    )

    await _run(db_session, "a colazione yogurt e frutta", llm, assistant)
    await db_session.refresh(assistant)
    assert assistant.notes == "- Colazione: yogurt e frutta"

    llm = RecordingLLM(
        [
            _calls((NOTES_TOOL, {"action": "remove", "line": "Colazione"})),
            _text("Tolto."),
        ]
    )
    await _run(db_session, "togli la colazione", llm, assistant)
    await db_session.refresh(assistant)
    assert assistant.notes == ""


async def test_full_notes_make_room_by_dropping_the_oldest_lines(db_session):
    old = "\n".join(f"- riga {i:04d} " + "x" * 80 for i in range(40))
    assistant = await _assistant(db_session, notes=old[: assistants.MAX_NOTES])
    llm = RecordingLLM(
        [
            _calls((NOTES_TOOL, {"action": "add", "line": "Cena: minestrone"})),
            _text("Annotato."),
        ]
    )

    await _run(db_session, "a cena minestrone", llm, assistant)
    await db_session.refresh(assistant)

    assert len(assistant.notes) <= assistants.MAX_NOTES
    assert assistant.notes.endswith("- Cena: minestrone")
    assert "riga 0000" not in assistant.notes


async def test_a_routine_made_in_its_chat_belongs_to_it(db_session):
    assistant = await _assistant(db_session)
    llm = RecordingLLM(
        [
            _calls(
                (
                    "ECHO_CREATE_ROUTINE",
                    {
                        "instruction": "chiedimi cosa ho mangiato",
                        "kind": "daily",
                        "time": "21:00",
                    },
                )
            ),
            _text("Fatto."),
        ]
    )

    await _run(db_session, "ogni sera alle 21 chiedimi cosa ho mangiato", llm, assistant)
    await db_session.commit()

    [routine] = (
        await db_session.scalars(select(Routine).where(Routine.user_id == TEST_USER_ID))
    ).all()
    assert routine.assistant_id == assistant.id


async def test_its_memory_search_uses_only_its_documents(db_session, monkeypatch):
    assistant = await _assistant(db_session, document_ids=[str(uuid.uuid4())])
    asked = {}

    async def _retrieve(db, user_id, query, **kwargs):
        asked.update(kwargs)
        return MemoryContext(context="")

    monkeypatch.setattr(agent_module, "retrieve_memory_context", _retrieve)
    llm = RecordingLLM([_calls(("search_memory", {"query": "piano pasti"})), _text("Ok.")])

    await _run(db_session, "cosa dice il piano pasti?", llm, assistant)

    assert asked["document_ids"] == assistant.document_ids


async def test_retrieval_limited_to_some_documents_quotes_no_other(db_session):
    mock = MockEmbeddingService()
    question = "piano pasti"
    chosen, other = [], []
    for title, bucket in (("Piano.pdf", chosen), ("Altro.pdf", other)):
        document = Document(
            id=uuid.uuid4(),
            user_id=TEST_USER_ID,
            title=title,
            kind="pdf",
            size_bytes=1,
            status="ready",
            text=title,
            word_count=1,
        )
        db_session.add(document)
        await db_session.flush()
        db_session.add(
            DocumentChunk(
                document_id=document.id,
                user_id=TEST_USER_ID,
                chunk_index=0,
                text=title,
                embedding=await mock.embed(question),
            )
        )
        bucket.append(str(document.id))
    await db_session.commit()

    memory = await retrieve_memory_context(
        db_session, TEST_USER_ID, question, embedding_service=mock, document_ids=chosen
    )

    assert "Piano.pdf" in memory.context
    assert "Altro.pdf" not in memory.context
