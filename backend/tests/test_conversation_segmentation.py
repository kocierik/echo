"""Unit tests: when a segment opens a new conversation."""

import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from app.core.config import settings
from app.services import analysis_pipeline
from app.services.analysis_pipeline import assign_to_conversation, starts_new_conversation

START = datetime(2026, 10, 13, 9, 0, tzinfo=timezone.utc)
TIMEOUT = timedelta(milliseconds=settings.silence_timeout_ms)


def _conversation(started_at=START, ended_at=None):
    return SimpleNamespace(id=uuid.uuid4(), started_at=started_at, ended_at=ended_at)


def _segment(recorded_at, silence_before_ms=0, duration_ms=6000):
    return SimpleNamespace(
        user_id=uuid.uuid4(),
        recorded_at=recorded_at,
        silence_before_ms=silence_before_ms,
        duration_ms=duration_ms,
        conversation_id=None,
    )


def test_first_segment_opens_a_conversation():
    assert starts_new_conversation(None, _segment(START))


def test_close_segment_extends_the_conversation():
    latest = _conversation(ended_at=START + timedelta(seconds=30))

    assert not starts_new_conversation(latest, _segment(START + timedelta(seconds=40)))


def test_device_silence_opens_a_new_conversation():
    latest = _conversation(ended_at=START + timedelta(seconds=30))
    segment = _segment(START + timedelta(seconds=40), silence_before_ms=settings.silence_timeout_ms)

    assert starts_new_conversation(latest, segment)


def test_wall_clock_gap_opens_a_new_conversation_even_without_device_silence():
    # Background noise kept the VAD busy, so the device reports no silence
    latest = _conversation(ended_at=START + timedelta(minutes=1))
    segment = _segment(START + timedelta(minutes=1) + TIMEOUT, silence_before_ms=0)

    assert starts_new_conversation(latest, segment)


def test_conversation_is_split_after_the_maximum_duration():
    max_duration = timedelta(milliseconds=settings.max_conversation_duration_ms)
    latest = _conversation(ended_at=START + max_duration - timedelta(seconds=5))

    assert starts_new_conversation(latest, _segment(START + max_duration))


class _Result:
    def __init__(self, value):
        self.value = value

    def scalar_one_or_none(self):
        return self.value


class _FakeDb:
    def __init__(self, latest):
        self.latest = latest
        self.added = []

    async def execute(self, _query):
        return _Result(self.latest)

    def add(self, obj):
        obj.id = uuid.uuid4()
        self.added.append(obj)

    async def flush(self):
        pass


@pytest.mark.asyncio
async def test_new_conversation_records_the_segment_end():
    segment = _segment(START, duration_ms=6000)

    conversation = await assign_to_conversation(_FakeDb(None), segment)

    assert conversation.started_at == START
    assert conversation.ended_at == START + timedelta(seconds=6)
    assert segment.conversation_id == conversation.id


@pytest.mark.asyncio
async def test_late_out_of_order_segment_does_not_shrink_the_conversation():
    latest = _conversation(ended_at=START + timedelta(minutes=1))
    segment = _segment(START + timedelta(seconds=10), duration_ms=6000)

    conversation = await assign_to_conversation(_FakeDb(latest), segment)

    assert conversation is latest
    assert latest.ended_at == START + timedelta(minutes=1)


@pytest.mark.asyncio
async def test_extending_moves_the_end_forward():
    latest = _conversation(ended_at=START + timedelta(seconds=30))
    segment = _segment(START + timedelta(seconds=40), duration_ms=5000)

    await assign_to_conversation(_FakeDb(latest), segment)

    assert latest.ended_at == START + timedelta(seconds=45)


def test_segment_end_tolerates_missing_duration():
    assert analysis_pipeline._segment_end(_segment(START, duration_ms=None)) == START
