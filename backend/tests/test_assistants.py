"""Assistants (Profile → Assistants): made from a template or from scratch, edited, deleted;
at most ten, each with its own instructions, notes and documents."""

import uuid

import pytest

from app.models.assistant import Assistant
from app.models.document import Document
from app.services import assistants
from tests.conftest import TEST_USER_ID


async def _document(db, user_id=TEST_USER_ID):
    document = Document(
        id=uuid.uuid4(), user_id=user_id, title="Piano.pdf", kind="pdf", size_bytes=1,
        status="ready", text="x", word_count=1,
    )
    db.add(document)
    await db.commit()
    return document


async def test_templates_for_work_diet_and_sleep(client, auth_headers):
    templates = (await client.get("/api/assistants/templates", headers=auth_headers)).json()

    assert [t["key"] for t in templates] == ["work", "diet", "sleep"]
    diet = templates[1]
    assert diet["emoji"] and diet["name"]
    # Never a doctor
    assert "medical" in diet["instructions"].lower() or "medic" in diet["instructions"].lower()


async def test_one_made_from_a_template_then_edited(client, auth_headers, db_session):
    document = await _document(db_session)

    created = await client.post(
        "/api/assistants", headers=auth_headers, json={"template": "diet"}
    )
    assert created.status_code == 201
    made = created.json()
    assert made["notes"] == "" and made["document_ids"] == []

    edited = await client.patch(
        f"/api/assistants/{made['id']}",
        headers=auth_headers,
        json={"name": "Coach", "notes": "Vegetariano.", "document_ids": [str(document.id)]},
    )
    assert edited.status_code == 200
    body = edited.json()
    assert (body["name"], body["notes"], body["document_ids"]) == (
        "Coach", "Vegetariano.", [str(document.id)],
    )
    assert body["instructions"] == made["instructions"]

    listed = (await client.get("/api/assistants", headers=auth_headers)).json()["assistants"]
    assert [a["name"] for a in listed] == ["Coach"]


async def test_one_made_from_scratch(client, auth_headers):
    created = await client.post(
        "/api/assistants",
        headers=auth_headers,
        json={"name": "Viaggi", "emoji": "✈️", "instructions": "Aiutami con i viaggi."},
    )

    assert created.status_code == 201
    assert created.json()["emoji"] == "✈️"


@pytest.mark.parametrize("body", [
    {"name": "", "instructions": "x"},
    {"name": "x" * 41, "instructions": "x"},
    {"name": "Ok", "instructions": "x" * 2001},
    {"template": "astrology"},
])
async def test_what_does_not_fit_is_refused(client, auth_headers, body):
    response = await client.post("/api/assistants", headers=auth_headers, json=body)

    assert response.status_code == 422


async def test_notes_past_the_limit_are_refused(client, auth_headers):
    made = (await client.post(
        "/api/assistants", headers=auth_headers, json={"template": "work"}
    )).json()

    response = await client.patch(
        f"/api/assistants/{made['id']}", headers=auth_headers,
        json={"notes": "x" * (assistants.MAX_NOTES + 1)},
    )

    assert response.status_code == 422


async def test_only_the_users_own_documents(client, auth_headers, db_session):
    theirs = await _document(db_session, user_id=uuid.uuid4())
    made = (await client.post(
        "/api/assistants", headers=auth_headers, json={"template": "work"}
    )).json()

    response = await client.patch(
        f"/api/assistants/{made['id']}", headers=auth_headers,
        json={"document_ids": [str(theirs.id)]},
    )

    assert response.status_code == 422


async def test_at_most_ten(client, auth_headers, db_session):
    for i in range(assistants.MAX_ASSISTANTS):
        db_session.add(Assistant(
            user_id=TEST_USER_ID, name=f"A{i}", emoji="🤖", instructions="x",
        ))
    await db_session.commit()

    response = await client.post("/api/assistants", headers=auth_headers, json={"template": "work"})

    assert response.status_code == 409


async def test_delete_and_someone_elses_is_404(client, auth_headers, db_session):
    other = Assistant(user_id=uuid.uuid4(), name="Loro", emoji="🤖", instructions="x")
    db_session.add(other)
    await db_session.commit()
    made = (await client.post(
        "/api/assistants", headers=auth_headers, json={"template": "sleep"}
    )).json()

    assert (await client.delete(f"/api/assistants/{made['id']}", headers=auth_headers)).status_code == 204
    assert (await client.delete(f"/api/assistants/{other.id}", headers=auth_headers)).status_code == 404
    assert (await client.patch(
        f"/api/assistants/{other.id}", headers=auth_headers, json={"name": "x"}
    )).status_code == 404
