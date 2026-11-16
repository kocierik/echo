"""A chat question is one tracked run (core/runs.py): its model calls are its steps."""

import uuid

from app.core.runs import current_run
from app.routers import query
from tests.conftest import TEST_USER_ID


async def test_a_chat_question_runs_inside_a_tracked_run(client, auth_headers, monkeypatch):
    seen = []

    async def fake_answer(redis_client, body, user_id, db, progress=None, on_token=None):
        seen.append(current_run())
        return query.QueryResponse(answer="ok", sources=[], session_id=str(uuid.uuid4()))

    monkeypatch.setattr(query, "_answer_query", fake_answer)

    response = await client.post("/api/query", headers=auth_headers, json={"question": "ciao"})

    assert response.status_code == 200
    assert [(run.source, run.user_id) for run in seen] == [("chat", TEST_USER_ID)]
