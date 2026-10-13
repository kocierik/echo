"""Integration tests for entity CRUD endpoints."""
import uuid

import pytest
from sqlalchemy import text

from tests.conftest import TEST_USER_ID


@pytest.mark.asyncio
async def test_patch_entity(client, auth_headers, db_session):
    # Insert entity
    entity_id = uuid.uuid4()
    await db_session.execute(text(
        "INSERT INTO entities (id, user_id, entity_type, name, content, metadata) "
        "VALUES (:id, :uid, 'person', 'Marco', 'collega', '{}')"
    ), {"id": str(entity_id), "uid": str(TEST_USER_ID)})
    await db_session.commit()

    # Patch
    resp = await client.patch(
        f"/api/entities/{entity_id}",
        headers=auth_headers,
        json={"name": "Marco Rossi", "content": "collega di marketing"}
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Marco Rossi"


@pytest.mark.asyncio
async def test_delete_entity(client, auth_headers, db_session):
    entity_id = uuid.uuid4()
    await db_session.execute(text(
        "INSERT INTO entities (id, user_id, entity_type, name, metadata) "
        "VALUES (:id, :uid, 'note', 'Test', '{}')"
    ), {"id": str(entity_id), "uid": str(TEST_USER_ID)})
    await db_session.commit()

    resp = await client.delete(f"/api/entities/{entity_id}", headers=auth_headers)
    assert resp.status_code == 204


@pytest.mark.asyncio
async def test_delete_entity_not_found(client, auth_headers):
    fake_id = uuid.uuid4()
    resp = await client.delete(f"/api/entities/{fake_id}", headers=auth_headers)
    assert resp.status_code == 404
