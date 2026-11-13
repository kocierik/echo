"""Integration tests for POST /api/segments endpoint."""

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException
from httpx import AsyncClient

from app.models.segment import Segment
from app.models.transcription import Transcription
from app.routers import segments as segments_router
from tests.conftest import TEST_USER_ID


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
async def test_ingest_segment_rejects_audio_over_five_megabytes(client: AsyncClient, auth_headers):
    response = await client.post(
        "/api/segments",
        headers={
            **auth_headers,
            "X-Recorded-At": "2026-07-19T10:30:00Z",
            "X-Duration-Ms": "5000",
        },
        files={
            "audio": (
                "segment.adpcm",
                b"\x00" * (5 * 1024 * 1024 + 1),
                "application/octet-stream",
            )
        },
    )

    assert response.status_code == 413


@pytest.mark.asyncio
async def test_upload_audio_reader_limits_the_bytes_read():
    class Upload:
        requested_size = None

        async def read(self, size=-1):
            self.requested_size = size
            return b"x" * size

    upload = Upload()

    with pytest.raises(HTTPException) as exc_info:
        await segments_router._read_audio_limited(upload)

    assert exc_info.value.status_code == 413
    assert upload.requested_size == 5 * 1024 * 1024 + 1


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


@pytest.mark.asyncio
async def test_recent_segments_include_pending_and_completed_transcriptions(
    client: AsyncClient, auth_headers, db_session
):
    now = datetime.now(timezone.utc)
    completed = Segment(
        user_id=TEST_USER_ID,
        received_at=now,
        recorded_at=now,
        duration_ms=1600,
        audio_path="/tmp/completed.adpcm",
        audio_size_bytes=12800,
        audio_energy=4200,
        speaker="self",
        transcription_status="completed",
    )
    pending = Segment(
        user_id=TEST_USER_ID,
        received_at=now - timedelta(seconds=1),
        recorded_at=now - timedelta(seconds=1),
        duration_ms=1200,
        audio_path="/tmp/pending.adpcm",
        audio_size_bytes=9600,
        speaker="unknown",
        transcription_status="pending",
    )
    other_user = Segment(
        user_id=uuid.uuid4(),
        received_at=now + timedelta(seconds=1),
        recorded_at=now + timedelta(seconds=1),
        duration_ms=900,
        audio_path="/tmp/other.adpcm",
        audio_size_bytes=7200,
        transcription_status="pending",
    )
    db_session.add_all([completed, pending, other_user])
    await db_session.flush()
    db_session.add(
        Transcription(
            segment_id=completed.id,
            text="[Tu] Ricordami di chiamare Marco",
            language="it",
            stt_provider="test",
            stt_model="test",
        )
    )
    await db_session.commit()

    response = await client.get("/api/segments/recent?limit=10", headers=auth_headers)

    assert response.status_code == 200
    data = response.json()
    assert [item["id"] for item in data] == [str(completed.id), str(pending.id)]
    assert data[0]["text"] == "[Tu] Ricordami di chiamare Marco"
    assert data[0]["speaker"] == "self"
    assert data[0]["transcription_status"] == "completed"
    assert data[1]["text"] is None
    assert data[1]["conversation_id"] is None


@pytest.mark.asyncio
async def test_recent_segments_require_authentication(client: AsyncClient):
    response = await client.get("/api/segments/recent")

    assert response.status_code in (401, 403)


async def _ingest_at(client, auth_headers, recorded_at: datetime, duration_ms: int = 4000):
    response = await client.post(
        "/api/segments",
        headers={
            **auth_headers,
            "X-Recorded-At": recorded_at.isoformat(),
            "X-Duration-Ms": str(duration_ms),
        },
        files={"audio": ("segment.adpcm", uuid.uuid4().bytes * 64, "application/octet-stream")},
    )
    assert response.status_code == 201
    return response.json()["id"]


def _queued(queue: str) -> list:
    from app.main import app

    return [v.decode() if isinstance(v, bytes) else v for v in app.state.redis.lists.get(queue, [])]


@pytest.mark.asyncio
async def test_a_segment_just_spoken_is_queued_as_live(client: AsyncClient, auth_headers):
    now = datetime.now(timezone.utc)
    segment_id = await _ingest_at(client, auth_headers, now - timedelta(seconds=5))

    assert segment_id in _queued("queue:stt:live")
    assert segment_id not in _queued("queue:stt")


@pytest.mark.asyncio
async def test_a_backlog_segment_waits_its_turn(client: AsyncClient, auth_headers):
    now = datetime.now(timezone.utc)
    segment_id = await _ingest_at(client, auth_headers, now - timedelta(minutes=10))

    assert segment_id in _queued("queue:stt")
    assert segment_id not in _queued("queue:stt:live")


@pytest.mark.asyncio
async def test_a_segment_from_a_clock_ahead_is_live(client: AsyncClient, auth_headers):
    now = datetime.now(timezone.utc)
    segment_id = await _ingest_at(client, auth_headers, now + timedelta(minutes=2))

    assert segment_id in _queued("queue:stt:live")
