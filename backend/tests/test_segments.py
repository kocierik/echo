"""Integration tests for POST /api/segments endpoint."""

import pytest
from httpx import AsyncClient

from tests.conftest import TEST_API_KEY


@pytest.mark.asyncio
async def test_ingest_segment_success(client: AsyncClient, auth_headers, tmp_path):
    """Test successful audio segment ingestion."""
    # Create fake ADPCM audio data (just random bytes for testing)
    fake_audio = b"\x00\x11\x22\x33" * 1000  # 4KB

    response = await client.post(
        "/api/segments",
        headers={
            **auth_headers,
            "X-Recorded-At": "2026-07-19T10:30:00Z",
            "X-Duration-Ms": "5000",
            "X-Silence-Before-Ms": "3000",
        },
        files={"audio": ("segment.adpcm", fake_audio, "application/octet-stream")},
    )

    assert response.status_code == 201
    data = response.json()
    assert "id" in data
    assert data["duration_ms"] == 5000
    assert data["transcription_status"] == "pending"


@pytest.mark.asyncio
async def test_ingest_segment_no_auth(client: AsyncClient):
    """Test that requests without API key are rejected."""
    fake_audio = b"\x00" * 100

    response = await client.post(
        "/api/segments",
        headers={
            "X-Recorded-At": "2026-07-19T10:30:00Z",
            "X-Duration-Ms": "5000",
        },
        files={"audio": ("segment.adpcm", fake_audio, "application/octet-stream")},
    )

    assert response.status_code in (401, 403, 422)


@pytest.mark.asyncio
async def test_ingest_segment_invalid_key(client: AsyncClient):
    """Test that requests with invalid API key are rejected."""
    fake_audio = b"\x00" * 100

    response = await client.post(
        "/api/segments",
        headers={
            "X-API-Key": "wrong-key",
            "X-Recorded-At": "2026-07-19T10:30:00Z",
            "X-Duration-Ms": "5000",
        },
        files={"audio": ("segment.adpcm", fake_audio, "application/octet-stream")},
    )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_ingest_segment_empty_audio(client: AsyncClient, auth_headers):
    """Test that empty audio files are rejected."""
    response = await client.post(
        "/api/segments",
        headers={
            **auth_headers,
            "X-Recorded-At": "2026-07-19T10:30:00Z",
            "X-Duration-Ms": "5000",
        },
        files={"audio": ("segment.adpcm", b"", "application/octet-stream")},
    )

    assert response.status_code == 400


@pytest.mark.asyncio
async def test_ingest_segment_optional_silence(client: AsyncClient, auth_headers):
    """Test that silence_before_ms header is optional."""
    fake_audio = b"\x00\x11" * 500

    response = await client.post(
        "/api/segments",
        headers={
            **auth_headers,
            "X-Recorded-At": "2026-07-19T10:30:00Z",
            "X-Duration-Ms": "3000",
        },
        files={"audio": ("segment.adpcm", fake_audio, "application/octet-stream")},
    )

    assert response.status_code == 201
