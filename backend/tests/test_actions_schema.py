"""Metadata contracts for pending actions, the action log and chat session kind."""

import importlib.util
from pathlib import Path

from app.models import ActionLog, Base, ChatSession, PendingAction

MIGRATION = Path(__file__).parents[1] / "alembic" / "versions" / "007_actions.py"


def _load_migration():
    spec = importlib.util.spec_from_file_location("migration_007", MIGRATION)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_pending_actions_table_columns() -> None:
    table = Base.metadata.tables["pending_actions"]
    assert set(table.columns.keys()) == {
        "id", "user_id", "session_id", "source", "tool", "arguments", "summary",
        "status", "created_at", "expires_at", "resolved_at",
    }
    assert table.c.resolved_at.nullable is True
    assert table.c.status.nullable is False
    assert PendingAction.__table__ is table


def test_action_log_table_columns_and_index() -> None:
    table = Base.metadata.tables["action_log"]
    assert set(table.columns.keys()) == {
        "id", "user_id", "source", "toolkit", "tool", "arguments_summary",
        "outcome", "error", "created_at",
    }
    assert table.c.error.nullable is True
    assert ActionLog.__table__ is table
    assert ["user_id", "created_at"] in [
        [c.name for c in idx.columns] for idx in table.indexes
    ]


def test_chat_session_kind_defaults_to_chat() -> None:
    column = ChatSession.__table__.c.kind
    assert column.nullable is False
    assert column.default.arg == "chat"
    assert str(column.server_default.arg) == "chat"


def test_migration_007_chain_and_idempotence() -> None:
    module = _load_migration()
    assert module.revision == "007"
    assert module.down_revision == "006"
    source = MIGRATION.read_text(encoding="utf-8")
    assert "sa_inspect" in source
    for name in ("pending_actions", "action_log", "kind"):
        assert name in source
    assert "op.drop_table" in source and "op.drop_column" in source
