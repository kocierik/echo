"""Chatting with an assistant in Ask, and its routines: the agent answers as the assistant,
the chat remembers it, history shows it; deleting it leaves plain Echo."""

import uuid

from app.actions.provider import ActionProviderError
from app.models.assistant import Assistant
from app.models.chat_session import ChatSession
from app.models.document import Document
from app.models.routine import Routine
from app.models.routine_run import RoutineRun
from app.routers import query as query_router
from tests.conftest import TEST_USER_ID
from tests.conftest import test_session as session_factory
from tests.fakes.action_provider import FakeActionProvider
from tests.test_routines_worker import _LLM, NOW, _run


async def _assistant(db, user_id=TEST_USER_ID):
    assistant = Assistant(
        id=uuid.uuid4(), user_id=user_id, name="Dieta", emoji="🥗",
        instructions="Sei il mio coach per l'alimentazione.", notes="Vegetariano.",
    )
    db.add(assistant)
    await db.commit()
    return assistant


def _agent(monkeypatch):
    calls: list[dict] = []

    async def fake_agent(db, user_id, request, history, **kwargs):
        calls.append({"request": request, **kwargs})
        from app.actions.agent import AgentOutcome

        return AgentOutcome(answer="Stasera minestrone di verdure.")

    monkeypatch.setattr(query_router, "run_action_agent", fake_agent)
    return calls


async def test_a_question_to_an_assistant_goes_to_it(client, auth_headers, db_session, monkeypatch):
    assistant = await _assistant(db_session)
    calls = _agent(monkeypatch)

    # No tool word: without an assistant this would be a memory answer
    response = await client.post(
        "/api/query", headers=auth_headers,
        json={"question": "cosa mangio stasera?", "assistant_id": str(assistant.id)},
    )

    assert response.status_code == 200
    assert response.json()["answer"] == "Stasera minestrone di verdure."
    assert calls[0]["assistant"].id == assistant.id


async def test_its_chat_remembers_it_and_history_shows_it(
    client, auth_headers, db_session, monkeypatch
):
    assistant = await _assistant(db_session)
    _agent(monkeypatch)

    answered = (await client.post(
        "/api/query", headers=auth_headers,
        json={"question": "cosa mangio stasera?", "assistant_id": str(assistant.id)},
    )).json()

    listed = (await client.get("/api/chat-sessions", headers=auth_headers)).json()["items"]
    mine = next(s for s in listed if s["id"] == answered["session_id"])
    assert (mine["assistant_id"], mine["assistant_name"], mine["assistant_emoji"]) == (
        str(assistant.id), "Dieta", "🥗",
    )
    detail = (await client.get(
        f"/api/chat-sessions/{answered['session_id']}", headers=auth_headers
    )).json()
    assert detail["assistant_id"] == str(assistant.id)


async def test_someone_elses_assistant_is_404(client, auth_headers, db_session, monkeypatch):
    theirs = await _assistant(db_session, user_id=uuid.uuid4())
    _agent(monkeypatch)

    response = await client.post(
        "/api/query", headers=auth_headers,
        json={"question": "ciao", "assistant_id": str(theirs.id)},
    )

    assert response.status_code == 404


async def test_a_deleted_assistant_leaves_its_chat_to_echo(
    client, auth_headers, db_session, monkeypatch
):
    assistant = await _assistant(db_session)
    _agent(monkeypatch)
    answered = (await client.post(
        "/api/query", headers=auth_headers,
        json={"question": "cosa mangio stasera?", "assistant_id": str(assistant.id)},
    )).json()

    await client.delete(f"/api/assistants/{assistant.id}", headers=auth_headers)

    async with session_factory() as db:
        session = await db.get(ChatSession, uuid.UUID(answered["session_id"]))
    assert session is not None and session.assistant_id is None


async def test_its_routine_runs_as_it():
    async with session_factory() as db:
        assistant = await _assistant(db)
        db.add(Routine(
            id=uuid.uuid4(), user_id=TEST_USER_ID, instruction="chiedimi cosa ho mangiato",
            schedule={"kind": "daily", "time": "07:00"}, timezone="Europe/Rome", active=True,
            next_run_at=NOW, source="chat", mode="always", assistant_id=assistant.id,
        ))
        await db.commit()
    llm = _LLM(answer="Cosa hai mangiato oggi?")

    await _run(llm)

    system = llm.call_log[0][0].content
    assert '"Dieta"' in system and "Vegetariano." in system


async def test_a_reopened_chat_continues_with_its_assistant(
    client, auth_headers, db_session, monkeypatch
):
    assistant = await _assistant(db_session)
    calls = _agent(monkeypatch)
    answered = (await client.post(
        "/api/query", headers=auth_headers,
        json={"question": "cosa mangio stasera?", "assistant_id": str(assistant.id)},
    )).json()

    # Only the session: the chat says which assistant it is with
    response = await client.post(
        "/api/query", headers=auth_headers,
        json={"question": "e domani?", "session_id": answered["session_id"]},
    )

    assert response.status_code == 200
    assert calls[1]["assistant"].id == assistant.id


async def test_its_chat_still_answers_when_the_apps_are_unreachable(
    client, auth_headers, db_session, monkeypatch
):
    assistant = await _assistant(db_session)
    calls = _agent(monkeypatch)

    class Down(FakeActionProvider):
        async def connected_toolkits(self, user_id):
            raise ActionProviderError("Composio request timed out")

    monkeypatch.setattr(query_router, "get_action_provider", lambda: Down())

    response = await client.post(
        "/api/query", headers=auth_headers,
        json={"question": "a colazione yogurt e frutta", "assistant_id": str(assistant.id)},
    )

    # Its notes need no app: the agent runs, without app tools
    assert response.status_code == 200
    assert calls[0]["connected_toolkits"] == []


async def test_asking_about_its_routine_run_opens_its_chat(client, auth_headers, db_session):
    assistant = await _assistant(db_session)
    routine = Routine(
        id=uuid.uuid4(), user_id=TEST_USER_ID, instruction="chiedimi cosa ho mangiato",
        schedule={"kind": "daily", "time": "21:00"}, timezone="Europe/Rome", active=True,
        next_run_at=NOW, source="chat", mode="always", assistant_id=assistant.id,
    )
    db_session.add(routine)
    await db_session.flush()
    runs = [
        RoutineRun(
            id=uuid.uuid4(), routine_id=routine.id, user_id=TEST_USER_ID, ran_at=NOW,
            status="reported", text=text, sources=[],
        )
        for text in ("Cosa hai mangiato oggi?", "E stasera?")
    ]
    db_session.add_all(runs)
    await db_session.commit()

    first = (await client.post(f"/api/routine-runs/{runs[0].id}/ask", headers=auth_headers)).json()
    second = (await client.post(f"/api/routine-runs/{runs[1].id}/ask", headers=auth_headers)).json()

    # Its own chat, not the thread with Echo: the reply reaches the assistant and its notes
    assert first["session_id"] == second["session_id"]
    async with session_factory() as db:
        chat = await db.get(ChatSession, uuid.UUID(first["session_id"]))
    assert chat.kind == "chat" and chat.assistant_id == assistant.id
    assert [m["content"] for m in chat.messages] == ["Cosa hai mangiato oggi?", "E stasera?"]


async def test_deleting_a_document_takes_it_from_its_assistants(
    client, auth_headers, db_session
):
    document = Document(
        id=uuid.uuid4(), user_id=TEST_USER_ID, title="Piano.pdf", kind="pdf", size_bytes=1,
        status="ready", text="x", word_count=1,
    )
    db_session.add(document)
    await db_session.commit()
    assistant = await _assistant(db_session)
    assistant.document_ids = [str(document.id)]
    await db_session.commit()

    await client.delete(f"/api/documents/{document.id}", headers=auth_headers)

    # None left: it searches all of them, as the editor says
    async with session_factory() as db:
        assert (await db.get(Assistant, assistant.id)).document_ids == []
