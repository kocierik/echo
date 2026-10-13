import uuid

import pytest


@pytest.mark.asyncio
async def test_submit_positive_feedback(client, auth_headers):
    resp = await client.post("/api/query/feedback", headers=auth_headers, json={
        "session_id": str(uuid.uuid4()),
        "message_index": 0,
        "rating": "positive",
        "source_chunk_ids": []
    })
    assert resp.status_code == 201
