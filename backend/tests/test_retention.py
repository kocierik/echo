"""Unit tests for split audio retention without database or filesystem access."""

import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
from sqlalchemy.dialects import postgresql

from app.workers.retention import _build_retention_query, cleanup_old_audio


class _ScalarResult:
    def __init__(self, segments):
        self._segments = segments

    def all(self):
        return self._segments


class _Result:
    def __init__(self, segments):
        self._segments = segments

    def scalars(self):
        return _ScalarResult(self._segments)


class _FakeSession:
    def __init__(self, segments):
        self.segments = segments
        self.executed_query = None
        self.commit_count = 0
        self.delete_count = 0

    async def execute(self, query):
        self.executed_query = query
        params = query.compile(dialect=postgresql.dialect()).params
        cutoffs = sorted(value for value in params.values() if isinstance(value, datetime))
        incomplete_cutoff, completed_cutoff = cutoffs
        eligible = [
            segment
            for segment in self.segments
            if segment.audio_path
            and segment.recorded_at
            < (
                completed_cutoff
                if segment.transcription_status == "completed"
                else incomplete_cutoff
            )
        ]
        eligible.sort(key=lambda segment: (segment.recorded_at, segment.id))
        limit = query._limit_clause.value
        return _Result(eligible[:limit])

    async def commit(self):
        self.commit_count += 1

    async def delete(self, _segment):
        self.delete_count += 1


class _SessionContext:
    def __init__(self, session):
        self._session = session

    async def __aenter__(self):
        return self._session

    async def __aexit__(self, _exc_type, _exc, _traceback):
        return False


def _session_factory(session):
    return lambda: _SessionContext(session)


def _segment(status, recorded_at, path=None):
    return SimpleNamespace(
        id=uuid.uuid4(),
        transcription_status=status,
        recorded_at=recorded_at,
        audio_path=path,
        audio_size_bytes=512 if path else None,
        transcription=object(),
        conversation_id=uuid.uuid4(),
    )


def test_retention_query_uses_exact_split_cutoffs_and_concurrent_batch_locking():
    now = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)

    query = _build_retention_query(now)
    compiled = query.compile(dialect=postgresql.dialect())
    sql = " ".join(str(compiled).split())
    params = compiled.params

    assert "segments.transcription_status = " in sql
    assert "segments.transcription_status != " in sql
    assert "segments.audio_path IS NOT NULL" in sql
    assert "segments.audio_path != " in sql
    assert "ORDER BY segments.recorded_at ASC, segments.id ASC" in sql
    assert "LIMIT " in sql
    assert "FOR UPDATE SKIP LOCKED" in sql
    assert list(params.values()).count("completed") == 2
    assert now - timedelta(hours=24) in params.values()
    assert now - timedelta(days=7) in params.values()
    assert query._limit_clause.value == 100


@pytest.mark.asyncio
async def test_split_retention_boundaries_and_unknown_status():
    now = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
    completed_recent = _segment(
        "completed", now - timedelta(hours=23, minutes=59), "completed-recent.adpcm"
    )
    completed_expired = _segment(
        "completed", now - timedelta(hours=24, minutes=1), "completed-expired.adpcm"
    )
    incomplete_recent = [
        _segment(status, now - timedelta(days=6, hours=23), f"{status}-recent.adpcm")
        for status in ("pending", "processing", "failed")
    ]
    incomplete_expired = [
        _segment(status, now - timedelta(days=7, minutes=1), f"{status}-expired.adpcm")
        for status in ("pending", "processing", "failed")
    ]
    unknown_expired = _segment(
        "future-status", now - timedelta(days=7, minutes=1), "unknown-expired.adpcm"
    )
    segments = [
        completed_recent,
        completed_expired,
        *incomplete_recent,
        *incomplete_expired,
        unknown_expired,
    ]
    session = _FakeSession(segments)
    deleted_paths = []

    cleared = await cleanup_old_audio(
        now=now,
        session_factory=_session_factory(session),
        delete_file=deleted_paths.append,
    )

    assert cleared == 5
    assert completed_recent.audio_path == "completed-recent.adpcm"
    assert all(segment.audio_path for segment in incomplete_recent)
    assert completed_expired.audio_path is None
    assert all(segment.audio_path is None for segment in incomplete_expired)
    assert unknown_expired.audio_path is None
    assert session.commit_count == 1


@pytest.mark.asyncio
async def test_missing_file_clears_audio_fields_but_keeps_metadata_rows():
    now = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
    segment = _segment("completed", now - timedelta(days=2), "missing.adpcm")
    transcription = segment.transcription
    conversation_id = segment.conversation_id
    session = _FakeSession([segment])

    def missing_file(_path):
        raise FileNotFoundError

    cleared = await cleanup_old_audio(
        now=now,
        session_factory=_session_factory(session),
        delete_file=missing_file,
    )

    assert cleared == 1
    assert segment in session.segments
    assert segment.audio_path is None
    assert segment.audio_size_bytes is None
    assert segment.transcription is transcription
    assert segment.conversation_id == conversation_id
    assert session.delete_count == 0


@pytest.mark.asyncio
async def test_delete_failure_preserves_audio_fields_for_retry():
    now = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
    segment = _segment("completed", now - timedelta(days=2), "locked.adpcm")
    session = _FakeSession([segment])

    def failed_delete(_path):
        raise PermissionError("in use")

    cleared = await cleanup_old_audio(
        now=now,
        session_factory=_session_factory(session),
        delete_file=failed_delete,
    )

    assert cleared == 0
    assert segment.audio_path == "locked.adpcm"
    assert segment.audio_size_bytes == 512
    assert session.commit_count == 1


@pytest.mark.asyncio
async def test_cleanup_is_oldest_first_capped_at_100_and_ignores_empty_paths():
    now = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
    eligible = [
        _segment(
            "processing",
            now - timedelta(days=8, minutes=index),
            f"segment-{index:03}.adpcm",
        )
        for index in range(102)
    ]
    null_path = _segment("completed", now - timedelta(days=2), None)
    empty_path = _segment("failed", now - timedelta(days=8), "")
    session = _FakeSession([*eligible, null_path, empty_path])
    deleted_paths = []
    expected = sorted(eligible, key=lambda segment: (segment.recorded_at, segment.id))[:100]
    expected_paths = [Path(segment.audio_path) for segment in expected]

    cleared = await cleanup_old_audio(
        now=now,
        session_factory=_session_factory(session),
        delete_file=deleted_paths.append,
    )

    assert cleared == 100
    assert deleted_paths == expected_paths
    assert all(segment.audio_path is None for segment in expected)
    assert sum(segment.audio_path is not None for segment in eligible) == 2
    assert null_path.audio_path is None
    assert empty_path.audio_path == ""


@pytest.mark.parametrize(
    "invalid_now",
    [
        datetime(2026, 10, 2, 12),
        datetime(2026, 10, 2, 12, tzinfo=timezone(timedelta(hours=1))),
    ],
)
def test_retention_query_requires_utc_aware_now(invalid_now):
    with pytest.raises(ValueError, match="UTC-aware"):
        _build_retention_query(invalid_now)