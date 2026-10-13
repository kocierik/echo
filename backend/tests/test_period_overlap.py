"""Unit tests: date filters select conversations that overlap the period."""

from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.dialects import postgresql

from app.models.conversation import Conversation
from app.services.temporal import conversation_overlaps

START = datetime(2026, 10, 13, 0, 0, tzinfo=timezone.utc)
END = datetime(2026, 10, 14, 0, 0, tzinfo=timezone.utc)


def _where_sql(conditions) -> str:
    query = select(Conversation.id).where(*conditions)
    compiled = query.compile(
        dialect=postgresql.dialect(), compile_kwargs={"literal_binds": True}
    )
    return " ".join(str(compiled).split("WHERE", 1)[1].split())


def test_closed_period_matches_any_overlap():
    sql = _where_sql(conversation_overlaps(START, END))

    # Started before the end of the period...
    assert "conversations.started_at < '2026-10-14 00:00:00+00:00'" in sql
    # ...and ended (or, if still open, started) at or after its start
    assert (
        "coalesce(conversations.ended_at, conversations.started_at) >= "
        "'2026-10-13 00:00:00+00:00'"
    ) in sql


def test_open_start_only_bounds_the_end():
    sql = _where_sql(conversation_overlaps(None, END))

    assert "started_at <" in sql
    assert "coalesce" not in sql


def test_open_end_only_bounds_the_start():
    sql = _where_sql(conversation_overlaps(START, None))

    assert "coalesce(conversations.ended_at, conversations.started_at) >=" in sql
    assert "started_at <" not in sql


def test_no_bounds_means_no_conditions():
    assert conversation_overlaps(None, None) == []


class _Rows:
    def __init__(self, rows):
        self.rows = rows

    def scalar_one_or_none(self):
        return self.rows[0] if self.rows else None

    def scalars(self):
        return self

    def all(self):
        return self.rows


class _RecordingDb:
    def __init__(self, conversation):
        self.conversation = conversation
        self.queries = []

    async def execute(self, query):
        self.queries.append(query)
        # 1: existing digest (none), 2: conversations, 3: transcriptions (none)
        return _Rows([self.conversation] if len(self.queries) == 2 else [])


async def test_digest_reads_only_what_was_said_that_day():
    import uuid
    from datetime import date
    from types import SimpleNamespace

    from app.workers.digest import generate_digest_for_date

    conversation = SimpleNamespace(id=uuid.uuid4(), title=None, summary=None)
    db = _RecordingDb(conversation)

    assert await generate_digest_for_date(uuid.uuid4(), date(2026, 10, 13), db) is None

    conversations_sql, transcriptions_sql = (_where_sql_of(q) for q in db.queries[1:3])
    assert "coalesce(conversations.ended_at, conversations.started_at) >=" in conversations_sql
    assert "segments.recorded_at >= '2026-10-13 00:00:00+02:00'" in transcriptions_sql
    assert "segments.recorded_at < '2026-10-14 00:00:00+02:00'" in transcriptions_sql


def _where_sql_of(query) -> str:
    compiled = query.compile(
        dialect=postgresql.dialect(), compile_kwargs={"literal_binds": True}
    )
    return " ".join(str(compiled).split())
