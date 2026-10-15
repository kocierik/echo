"""Weekly summaries: written from the week's days, conversations and people."""

from datetime import date, datetime, time, timedelta

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import user_zone
from app.models import Digest
from app.services import weekly_digest as weekly
from app.services.entity_mentions import record_mentions
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation, make_entity

WEEK = date(2026, 10, 5)  # a Monday


class WeekLLM:
    def __init__(self):
        self.prompts = []

    async def complete_json(self, messages, temperature=0.1):
        self.prompts.append(messages[-1].content)
        return {
            "summary": "A week of planning the demo with Marco.",
            "highlights": ["Demo moved to Friday", "", "Quote from Marco on Monday"],
        }


def _at(day: date, hour: int) -> datetime:
    return datetime.combine(day, time(hour), tzinfo=user_zone())


async def _week_with_marco(db: AsyncSession):
    first, _ = await make_conversation(
        db, started_at=_at(WEEK, 10), title="Demo", summary="Planned the demo.", texts=()
    )
    second, _ = await make_conversation(
        db, started_at=_at(WEEK + timedelta(days=3), 15), title="Quote", summary=None, texts=()
    )
    # The following Monday is another week
    await make_conversation(db, started_at=_at(WEEK + timedelta(days=7), 9), title="Next", texts=())
    marco = make_entity(first, "person", "Marco")
    task = make_entity(second, "task", "Send the quote")
    db.add_all([marco, task])
    await db.flush()
    await record_mentions(db, [marco])
    marco.conversation_id = second.id
    await record_mentions(db, [marco])
    db.add(Digest(user_id=TEST_USER_ID, digest_date=WEEK, summary="I planned the demo."))
    await db.commit()


@pytest.mark.asyncio
async def test_a_week_is_summarized_from_its_days_and_conversations(db_session: AsyncSession):
    await _week_with_marco(db_session)
    llm = WeekLLM()

    summary = await weekly.generate_weekly_digest(db_session, TEST_USER_ID, WEEK, llm)

    assert summary.summary == "A week of planning the demo with Marco."
    assert summary.highlights == ["Demo moved to Friday", "Quote from Marco on Monday"]
    assert summary.conversation_count == 2
    assert summary.people == [{"name": "Marco", "conversations": 2}]
    prompt = llm.prompts[0]
    assert "I planned the demo." in prompt and "Demo: Planned the demo." in prompt
    assert "Quote" in prompt and "Next" not in prompt
    assert "Marco (2)" in prompt

    # Already written: returned as is, unless replaced
    again = await weekly.generate_weekly_digest(db_session, TEST_USER_ID, WEEK, llm)
    assert again.id == summary.id and len(llm.prompts) == 1
    replaced = await weekly.generate_weekly_digest(
        db_session, TEST_USER_ID, WEEK, llm, replace=True
    )
    assert replaced.id != summary.id and len(llm.prompts) == 2


@pytest.mark.asyncio
async def test_an_empty_week_has_no_summary(db_session: AsyncSession):
    assert await weekly.generate_weekly_digest(
        db_session, TEST_USER_ID, WEEK - timedelta(weeks=10), WeekLLM()
    ) is None
    with pytest.raises(ValueError):
        await weekly.generate_weekly_digest(
            db_session, TEST_USER_ID, WEEK + timedelta(days=1), WeekLLM()
        )


def test_the_week_starts_on_monday():
    assert weekly.week_start_of(date(2026, 10, 11)) == WEEK  # Sunday
    assert weekly.week_start_of(WEEK) == WEEK


@pytest.mark.asyncio
async def test_weekly_endpoints(client, auth_headers, db_session: AsyncSession, monkeypatch):
    await _week_with_marco(db_session)
    monkeypatch.setattr("app.routers.digest.get_llm_analysis_service", WeekLLM)

    created = await client.post(f"/api/digest/weekly/{WEEK}", headers=auth_headers)
    assert created.status_code == 200
    assert created.json()["highlights"][0] == "Demo moved to Friday"

    listed = await client.get("/api/digest/weekly?weeks=52", headers=auth_headers)
    assert [w["week_start"] for w in listed.json()["items"]] == [str(WEEK)]

    tuesday = await client.post(
        f"/api/digest/weekly/{WEEK + timedelta(days=1)}", headers=auth_headers
    )
    assert tuesday.status_code == 422
    future = await client.post("/api/digest/weekly/2099-01-05", headers=auth_headers)
    assert future.status_code == 400
    empty = await client.post("/api/digest/weekly/2020-01-06", headers=auth_headers)
    assert empty.status_code == 404
    # The daily digest route still takes dates
    assert (await client.get(f"/api/digest/{WEEK}", headers=auth_headers)).status_code == 200


@pytest.mark.asyncio
async def test_the_digest_loop_writes_the_week_after_sunday(monkeypatch):
    from app.workers import digest as worker

    calls = []

    async def daily(day):
        calls.append(("day", day))

    async def week(start):
        calls.append(("week", start))

    monkeypatch.setattr(worker, "generate_digests_for_all_users", daily)
    monkeypatch.setattr(worker, "generate_weekly_digests_for_all_users", week)
    sunday = WEEK + timedelta(days=6)
    days = iter([sunday - timedelta(days=1), sunday, sunday + timedelta(days=1)])
    monkeypatch.setattr(worker, "next_digest_run", lambda now: (now, next(days)))
    stops = iter([False, False, True])

    async def no_wait(seconds, event):
        return next(stops)

    monkeypatch.setattr(worker, "sleep_or_shutdown", no_wait)
    await worker.run_digest_loop()

    assert calls == [("day", sunday - timedelta(days=1)), ("day", sunday), ("week", WEEK)]
