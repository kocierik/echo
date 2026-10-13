"""Unit tests: digest schedule in the user's timezone, rule speaker condition, metrics auth."""

import uuid
from datetime import date, datetime, timezone
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app import main
from app.core.timezone import local_day_bounds
from app.models.entity import Entity
from app.services import rules_engine
from app.workers.digest import next_digest_run

# --- Local day bounds and digest schedule (Europe/Rome, digest at 04:00) ---


def test_local_day_bounds_are_local_midnights():
    start, end = local_day_bounds(date(2026, 10, 13))

    assert start.isoformat() == "2026-10-13T00:00:00+02:00"
    assert end.isoformat() == "2026-10-14T00:00:00+02:00"
    assert start.astimezone(timezone.utc).hour == 22  # previous UTC day


def test_digest_runs_tonight_at_four_for_the_day_just_ended():
    now = datetime(2026, 10, 13, 20, 0, tzinfo=timezone.utc)  # 22:00 in Rome

    run_at, day = next_digest_run(now)

    assert run_at.isoformat() == "2026-10-14T04:00:00+02:00"
    assert day == date(2026, 10, 13)


def test_digest_after_midnight_but_before_four_runs_the_same_night():
    now = datetime(2026, 10, 13, 23, 30, tzinfo=timezone.utc)  # 01:30 on the 14th in Rome

    run_at, day = next_digest_run(now)

    assert run_at.isoformat() == "2026-10-14T04:00:00+02:00"
    assert day == date(2026, 10, 13)


def test_digest_after_four_waits_for_the_next_night():
    now = datetime(2026, 10, 14, 3, 0, tzinfo=timezone.utc)  # 05:00 in Rome

    run_at, day = next_digest_run(now)

    assert run_at.isoformat() == "2026-10-15T04:00:00+02:00"
    assert day == date(2026, 10, 14)


# --- Rule speaker condition ---


def _entity():
    return Entity(
        user_id=uuid.uuid4(),
        entity_type="task",
        name="Chiamare Ada",
        content="Chiamare Ada domani",
        metadata_={},
        source_transcription_id=uuid.uuid4(),
    )


@pytest.mark.parametrize(
    ("value", "expected"),
    [("self", "self"), ("Tu", "self"), ("[Tu]", "self"), ("you", "self"),
     ("altri", "other"), ("Others", "other"), ("unknown", "unknown"), ("boh", None), (None, None)],
)
def test_speaker_aliases(value, expected):
    assert rules_engine.normalize_speaker(value) == expected


def test_speaker_condition_uses_the_segment_speaker():
    conditions = {"entity_type": "task", "speaker": "tu"}

    assert rules_engine._matches_conditions(conditions, _entity(), speaker="self")
    assert not rules_engine._matches_conditions(conditions, _entity(), speaker="other")
    assert not rules_engine._matches_conditions(conditions, _entity(), speaker=None)


class _Rows:
    def __init__(self, rows):
        self.rows = rows

    def first(self):
        return self.rows[0] if self.rows else None

    def scalars(self):
        return self

    def all(self):
        return self.rows


class _FakeDb:
    def __init__(self, rules, speaker_row):
        self.rules = rules
        self.speaker_row = speaker_row
        self.queries = 0

    async def execute(self, _query):
        self.queries += 1
        if self.queries == 1:
            return _Rows(self.rules)
        return _Rows([self.speaker_row] if self.speaker_row else [])


def _rule(conditions):
    return SimpleNamespace(
        name="r", conditions=conditions, actions=[], trigger_count=0, last_triggered_at=None
    )


@pytest.mark.asyncio
async def test_corrected_speaker_label_wins_over_the_energy_guess():
    db = _FakeDb([_rule({"speaker": "self"})], ("self", "other"))

    assert await rules_engine.evaluate_rules(db, uuid.uuid4(), _entity()) == 1


@pytest.mark.asyncio
async def test_energy_speaker_is_used_without_a_correction():
    db = _FakeDb([_rule({"speaker": "self"})], (None, "other"))

    assert await rules_engine.evaluate_rules(db, uuid.uuid4(), _entity()) == 0


@pytest.mark.asyncio
async def test_speaker_is_not_looked_up_without_speaker_rules():
    db = _FakeDb([_rule({"entity_type": "task"})], ("self", "self"))

    assert await rules_engine.evaluate_rules(db, uuid.uuid4(), _entity()) == 1
    assert db.queries == 1


# --- /metrics authorization ---


def _request(headers):
    return SimpleNamespace(headers=headers)


@pytest.mark.asyncio
async def test_metrics_accepts_the_configured_bearer_token(monkeypatch):
    monkeypatch.setattr(main.settings, "metrics_token", "scrape-secret")

    await main._authorize_metrics(_request({"authorization": "Bearer scrape-secret"}))


@pytest.mark.asyncio
async def test_metrics_rejects_missing_or_wrong_credentials(monkeypatch):
    monkeypatch.setattr(main.settings, "metrics_token", "scrape-secret")

    for headers in ({}, {"authorization": "Bearer nope"}):
        with pytest.raises(HTTPException) as exc:
            await main._authorize_metrics(_request(headers))
        assert exc.value.status_code == 401
