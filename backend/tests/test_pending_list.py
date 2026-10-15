"""GET /api/actions/pending: what Today shows under "Needs you"."""

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import PendingAction
from tests.conftest import TEST_USER_ID

def _pending(
    summary: str,
    *,
    status="pending",
    expires_in=timedelta(minutes=20),
    age=timedelta(minutes=1),
    user_id=TEST_USER_ID,
    tool="GMAIL_SEND_EMAIL",
    source="voice",
):
    return PendingAction(
        id=uuid.uuid4(),
        user_id=user_id,
        source=source,
        tool=tool,
        arguments={"to": "marco@example.com"},
        summary=summary,
        status=status,
        # Now, not when the module was imported: a long run would expire them
        created_at=datetime.now(timezone.utc) - age,
        expires_at=datetime.now(timezone.utc) + expires_in,
    )


@pytest.mark.asyncio
async def test_lists_only_open_unexpired_actions_newest_first(
    client, auth_headers, db_session: AsyncSession
):
    db_session.add_all(
        [
            _pending("Send the budget to Marco", age=timedelta(minutes=5)),
            _pending(
                "Create the Atlas event",
                tool="GOOGLECALENDAR_CREATE_EVENT",
                source="chat",
                age=timedelta(minutes=1),
            ),
            _pending("Expired", expires_in=timedelta(minutes=-1)),
            _pending("Done already", status="executed"),
            _pending("Someone else's", user_id=uuid.uuid4()),
        ]
    )
    await db_session.commit()

    response = await client.get("/api/actions/pending", headers=auth_headers)

    assert response.status_code == 200
    body = response.json()
    assert [a["summary"] for a in body] == ["Create the Atlas event", "Send the budget to Marco"]
    assert [a["app"] for a in body] == ["Google Calendar", "Gmail"]
    assert [a["source"] for a in body] == ["chat", "voice"]
