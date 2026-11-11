"""Integration tests for segment ingest idempotency.

Verifies that duplicate audio segments (same content + recorded_at) are
detected and not processed twice.
"""

import uuid

import pytest
from httpx import AsyncClient

from app.core.auth import hash_api_key
from app.main import app
from app.models.api_key import ApiKey
from tests.fakes.redis import InMemoryRedis


@pytest.mark.asyncio
async def test_duplicate_segment_returns_same_id(client: AsyncClient, auth_headers):
    """Sending the same audio with same recorded_at should return the original segment."""
    fake_audio = b"\xAA\xBB\xCC\xDD" * 500  # 2KB

    headers = {
        **auth_headers,
        "X-Recorded-At": "2026-07-20T14:00:00Z",
        "X-Duration-Ms": "5000",
    }
    files = {"audio": ("segment.adpcm", fake_audio, "application/octet-stream")}

    # First request — creates the segment
    response1 = await client.post("/api/segments", headers=headers, files=files)
    assert response1.status_code == 201
    data1 = response1.json()

    # Second request — same audio, same recorded_at → idempotent return
    files2 = {"audio": ("segment.adpcm", fake_audio, "application/octet-stream")}
    response2 = await client.post("/api/segments", headers=headers, files=files2)

    # Should succeed (not error) and return the same segment
    assert response2.status_code == 201
    data2 = response2.json()
    assert data2["id"] == data1["id"]


@pytest.mark.asyncio
async def test_different_audio_creates_new_segment(client: AsyncClient, auth_headers):
    """Different audio content should create a new segment even with same timestamp."""
    headers = {
        **auth_headers,
        "X-Recorded-At": "2026-07-20T15:00:00Z",
        "X-Duration-Ms": "3000",
    }

    # First audio
    response1 = await client.post(
        "/api/segments",
        headers=headers,
        files={"audio": ("a.adpcm", b"\x01" * 1000, "application/octet-stream")},
    )
    assert response1.status_code == 201

    # Different audio, same timestamp
    response2 = await client.post(
        "/api/segments",
        headers=headers,
        files={"audio": ("b.adpcm", b"\x02" * 1000, "application/octet-stream")},
    )
    assert response2.status_code == 201

    # Should be different segments
    assert response1.json()["id"] != response2.json()["id"]


@pytest.mark.asyncio
async def test_same_audio_different_timestamp_creates_new(client: AsyncClient, auth_headers):
    """Same audio content but different recorded_at should create a new segment."""
    fake_audio = b"\xDE\xAD\xBE\xEF" * 500

    response1 = await client.post(
        "/api/segments",
        headers={**auth_headers, "X-Recorded-At": "2026-07-20T16:00:00Z", "X-Duration-Ms": "4000"},
        files={"audio": ("s.adpcm", fake_audio, "application/octet-stream")},
    )
    assert response1.status_code == 201

    response2 = await client.post(
        "/api/segments",
        headers={**auth_headers, "X-Recorded-At": "2026-07-20T17:00:00Z", "X-Duration-Ms": "4000"},
        files={"audio": ("s.adpcm", fake_audio, "application/octet-stream")},
    )
    assert response2.status_code == 201

    assert response1.json()["id"] != response2.json()["id"]


@pytest.mark.asyncio
async def test_same_audio_for_different_users_creates_distinct_segments(
    client: AsyncClient, auth_headers, db_session
):
    other_user_id = uuid.uuid4()
    other_api_key = "other-user-test-key"
    db_session.add(
        ApiKey(user_id=other_user_id, key_hash=hash_api_key(other_api_key), name="test")
    )
    await db_session.commit()
    audio = b"\xA5" * 1000
    headers = {"X-Recorded-At": "2026-07-20T14:00:00Z", "X-Duration-Ms": "5000"}

    first = await client.post(
        "/api/segments",
        headers={**auth_headers, **headers},
        files={"audio": ("segment.adpcm", audio, "application/octet-stream")},
    )
    second = await client.post(
        "/api/segments",
        headers={"X-API-Key": other_api_key, **headers},
        files={"audio": ("segment.adpcm", audio, "application/octet-stream")},
    )

    assert first.status_code == second.status_code == 201
    assert first.json()["id"] != second.json()["id"]


@pytest.mark.asyncio
async def test_idempotent_retry_requeues_a_segment_when_redis_failed(
    client: AsyncClient, auth_headers
):
    class FailFirstEnqueue(InMemoryRedis):
        def __init__(self):
            super().__init__()
            self.failed = False

        async def lpush(self, key, *values):
            if key == "queue:stt" and not self.failed:
                self.failed = True
                raise ConnectionError("redis unavailable")
            return await super().lpush(key, *values)

    redis = FailFirstEnqueue()
    app.state.redis = redis
    headers = {
        **auth_headers,
        "X-Recorded-At": "2026-07-20T14:00:00Z",
        "X-Duration-Ms": "5000",
    }
    audio = b"\xAA\xBB\xCC\xDD" * 500

    with pytest.raises(ConnectionError, match="redis unavailable"):
        await client.post(
            "/api/segments",
            headers=headers,
            files={"audio": ("segment.adpcm", audio, "application/octet-stream")},
        )

    retry = await client.post(
        "/api/segments",
        headers=headers,
        files={"audio": ("segment.adpcm", audio, "application/octet-stream")},
    )

    assert retry.status_code == 201
    assert redis.lists["queue:stt"] == [retry.json()["id"]]
