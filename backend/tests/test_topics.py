from datetime import datetime, timedelta, timezone

import pytest

from app.cli.backfill_topics import backfill_topics, parse_args
from app.services.topics import normalize_topics


def test_topics_are_normalized():
    assert normalize_topics(
        ["Atlas", " atlas ", "The Move", "Marco", "a b c d", ""], ["Marco"]
    ) == ["atlas", "the move"]


def test_a_non_list_is_no_topics():
    assert normalize_topics("x", []) == []


async def test_backfill_topics_only_selects_missing_recent_summaries():
    from tests.conftest import test_session
    from tests.factories import make_conversation

    now = datetime(2026, 11, 10, tzinfo=timezone.utc)
    async with test_session() as db:
        eligible, _ = await make_conversation(
            db, started_at=now - timedelta(days=10), title="Eligible", summary="Summary"
        )
        already_set, _ = await make_conversation(
            db,
            started_at=now - timedelta(days=9),
            title="Already set",
            summary="Summary",
        )
        already_set.topics = ["existing"]
        await make_conversation(
            db, started_at=now - timedelta(days=8), title="No summary", summary=None
        )
        await make_conversation(
            db, started_at=now - timedelta(days=91), title="Too old", summary="Summary"
        )
        eligible_id = eligible.id
        await db.commit()

    class _LLM:
        def __init__(self):
            self.messages = []

        async def complete_json(self, messages):
            self.messages.append(messages)
            return {"topics": ["Recent topic"]}

    llm = _LLM()
    processed = await backfill_topics(
        days=90, session_factory=test_session, llm_service=llm, now=now
    )

    assert processed == 1
    assert len(llm.messages) == 1
    async with test_session() as db:
        from app.models.conversation import Conversation

        assert (await db.get(Conversation, eligible_id)).topics == ["recent topic"]


async def test_backfill_uses_summary_only_and_commits_in_batches():
    from sqlalchemy import event
    from sqlalchemy.orm import Session

    from tests.conftest import test_session
    from tests.factories import make_conversation

    now = datetime(2026, 11, 10, tzinfo=timezone.utc)
    async with test_session() as db:
        for index in range(21):
            await make_conversation(
                db,
                started_at=now - timedelta(days=1, seconds=index),
                title=f"Title {index}",
                summary=f"Summary {index}",
                texts=(f"private transcript sentinel {index}",),
            )
        await db.commit()

    commits = 0

    def count_commit(*_args):
        nonlocal commits
        commits += 1

    class _LLM:
        def __init__(self):
            self.calls = 0

        async def complete_json(self, messages):
            self.calls += 1
            if self.calls == 21:
                assert commits == 1
            prompt = messages[-1].content
            index = prompt.split("Title: Title ", 1)[1].splitlines()[0]
            assert f"Summary {index}" in prompt
            assert "private transcript sentinel" not in prompt
            return {"topics": ["topic"]}

    llm = _LLM()
    event.listen(Session, "before_commit", count_commit)
    try:
        processed = await backfill_topics(
            days=90, session_factory=test_session, llm_service=llm, now=now
        )
    finally:
        event.remove(Session, "before_commit", count_commit)

    assert processed == 21
    assert llm.calls == 21
    assert commits == 2


@pytest.mark.parametrize("days", [0, -1, 3651])
def test_backfill_rejects_days_outside_supported_range(days):
    with pytest.raises(SystemExit):
        parse_args(["--days", str(days)])
