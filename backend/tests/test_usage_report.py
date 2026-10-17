"""make usage: what a day of Echo costs, per user and kind of work, from the usage table."""

import uuid
from datetime import datetime, timedelta, timezone

import pytest

from app.models.action_log import ActionLog
from app.models.llm_usage import LlmUsage
from app.services import usage_report
from app.services.usage_report import summarize
from app.services.usage_report import usage_report as report
from tests.conftest import TEST_USER_ID

PRICES = {
    "gpt-6-luna": {"unit": "token", "input": 0.10, "cached": 0.01, "output": 0.50},
    "gpt-4o-transcribe": {"unit": "second", "per_minute": 0.006},
}
TODAY = datetime.now(timezone.utc).date()


@pytest.fixture(autouse=True)
def _prices(monkeypatch):
    monkeypatch.setattr(usage_report, "PRICES", PRICES)


def _row(kind, model, day=TODAY, user=TEST_USER_ID, **units):
    return LlmUsage(
        id=uuid.uuid4(), user_id=user, day=day, kind=kind, model=model, calls=1,
        input_units=units.get("input", 0), output_units=units.get("output", 0),
        cached_units=units.get("cached", 0),
    )


async def test_costs_follow_the_price_table(db_session):
    db_session.add_all([
        _row("llm_query", "gpt-6-luna", input=1_000_000, output=100_000),
        _row("llm_analysis", "gpt-6-luna", input=1_000_000, cached=500_000),
        _row("stt", "gpt-4o-transcribe", input=600),
    ])
    await db_session.commit()

    rows = {(r.kind): r for r in await report(db_session, days=7)}

    assert rows["llm_query"].usd == pytest.approx(0.10 + 0.05)
    # Cached tokens are part of the input, at the cached price
    assert rows["llm_analysis"].usd == pytest.approx(0.05 + 0.005)
    assert rows["stt"].usd == pytest.approx(0.06)


async def test_unknown_models_cost_unknown(db_session):
    db_session.add(_row("llm_query", "some-new-model", input=1000))
    await db_session.commit()

    [row] = await report(db_session, days=7)

    assert row.usd is None
    assert "?" in summarize([row], {})


async def test_cost_per_hour_of_speech(db_session):
    yesterday = TODAY - timedelta(days=1)
    db_session.add_all([
        _row("stt", "gpt-4o-transcribe", input=900),  # $0.09
        _row("stt", "gpt-4o-transcribe", day=yesterday, input=900),  # $0.09
        _row("llm_query", "gpt-6-luna", input=3_200_000),  # $0.32
    ])
    await db_session.commit()

    text = summarize(await report(db_session, days=7), {})

    # $0.50 for 1800 s of speech
    assert "$1.00 per hour of speech" in text


async def test_old_days_are_left_out(db_session):
    db_session.add(_row("stt", "gpt-4o-transcribe", day=TODAY - timedelta(days=30), input=60))
    await db_session.commit()

    assert await report(db_session, days=7) == []


async def test_composio_actions_are_counted(db_session):
    db_session.add(_row("stt", "gpt-4o-transcribe", input=60))
    for outcome in ("ok", "ok", "error"):
        db_session.add(ActionLog(
            user_id=TEST_USER_ID, source="chat", toolkit="gmail", tool="GMAIL_SEND_EMAIL",
            arguments_summary="", outcome=outcome,
        ))
    await db_session.commit()

    counts = await usage_report.composio_actions(db_session, days=7)

    assert counts == {TEST_USER_ID: 2}
    assert "Composio actions: 2" in summarize(await report(db_session, days=7), counts)

