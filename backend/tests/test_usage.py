"""Model usage per user and day: what a day of Echo costs, before any price is set."""

import logging

from sqlalchemy import select

from app.models.llm_usage import LlmUsage
from app.services import usage
from app.services.usage import owned_by, record_usage, usage_owner
from tests.conftest import TEST_USER_ID, test_session


async def _rows():
    async with test_session() as db:
        query = select(LlmUsage).order_by(LlmUsage.kind, LlmUsage.model)
        return (await db.execute(query)).scalars().all()


async def test_calls_add_up_in_one_row_per_day_kind_model():
    with owned_by(TEST_USER_ID):
        await record_usage("llm_query", "m", input_units=100, output_units=20,
                           session_factory=test_session)
        await record_usage("llm_query", "m", input_units=100, output_units=20,
                           session_factory=test_session)

    [row] = await _rows()
    assert row.user_id == TEST_USER_ID
    assert (row.calls, row.input_units, row.output_units) == (2, 200, 40)


async def test_kinds_and_models_get_their_own_rows():
    with owned_by(TEST_USER_ID):
        for kind, model in [("llm_query", "m"), ("llm_query", "n"), ("embedding", "m")]:
            await record_usage(kind, model, input_units=1, session_factory=test_session)

    assert [(r.kind, r.model) for r in await _rows()] == [
        ("embedding", "m"), ("llm_query", "m"), ("llm_query", "n"),
    ]


async def test_work_with_no_owner_is_kept_under_no_user(caplog, monkeypatch):
    monkeypatch.setattr(usage, "_warned_unowned", set())
    with caplog.at_level(logging.WARNING, logger="app.services.usage"):
        await record_usage("llm_intent", "m", input_units=5, session_factory=test_session)
        await record_usage("llm_intent", "m", input_units=5, session_factory=test_session)

    [row] = await _rows()
    assert row.user_id is None and row.calls == 2
    warnings = [r for r in caplog.records if "llm_intent" in r.getMessage()]
    assert len(warnings) == 1


async def test_a_failed_write_never_raises(caplog):
    class _Broken:
        async def __aenter__(self):
            raise RuntimeError("database down")

        async def __aexit__(self, *exc):
            return False

    with caplog.at_level(logging.WARNING, logger="app.services.usage"), owned_by(TEST_USER_ID):
        result = await record_usage("stt", "m", input_units=3, session_factory=_Broken)

    assert result is None
    assert any("usage" in r.getMessage().lower() for r in caplog.records)


def test_owned_by_resets():
    with owned_by(TEST_USER_ID):
        assert usage_owner.get() == TEST_USER_ID
    assert usage_owner.get() is None
