"""Integration tests for segment ingest idempotency.

Verifies that duplicate audio segments (same content + recorded_at) are
detected and not processed twice.
"""

import pytest
from httpx import AsyncClient


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
