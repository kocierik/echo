"""GET /export: everything about the user, nothing about others, no vectors."""

import json
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ChatSession
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation, make_entity


@pytest.mark.asyncio
async def test_the_export_has_conversations_entities_and_chats(
    client, auth_headers, db_session: AsyncSession
):
    started = datetime.now(timezone.utc) - timedelta(days=1)
    conversation, _ = await make_conversation(
        db_session, started_at=started, title="Pranzo", texts=("[You] Domani chiamo Ada.",)
    )
    task = make_entity(conversation, "task", "Chiamare Ada", metadata={"done": False})
    task.embedding = [0.1] * 1536
    db_session.add(task)
    db_session.add(
        ChatSession(
            user_id=TEST_USER_ID,
            title="Ciao",
            kind="chat",
            messages=[{"role": "user", "content": "Ciao"}],
            created_at=started,
            updated_at=started,
        )
    )
    await make_conversation(
        db_session,
        started_at=started,
        title="Someone else's",
        user_id=uuid.uuid4(),
        texts=(),
    )
    await db_session.commit()

    response = await client.get("/api/export", headers=auth_headers)

    assert response.status_code == 200
    assert "attachment" in response.headers["content-disposition"]
    data = json.loads(response.content)
    assert data["format"] == "echo-export"
    assert [c["title"] for c in data["conversations"]] == ["Pranzo"]
    assert data["conversations"][0]["transcript"][0]["text"] == "[You] Domani chiamo Ada."
    assert [e["name"] for e in data["entities"]] == ["Chiamare Ada"]
    assert "embedding" not in json.dumps(data)
    assert any(chat["title"] == "Ciao" for chat in data["chats"])
