"""Add pending actions, action log and chat session kind.

Revision ID: 007
Revises: 006
Create Date: 2026-10-13

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "007"
down_revision: Union[str, None] = "006"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _index_names(table_name: str) -> set[str]:
    inspector = sa_inspect(op.get_bind())
    if table_name not in inspector.get_table_names():
        return set()
    return {index["name"] for index in inspector.get_indexes(table_name)}


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    tables = set(inspector.get_table_names())

    if "chat_sessions" in tables:
        columns = {column["name"] for column in inspector.get_columns("chat_sessions")}
        if "kind" not in columns:
            op.add_column(
                "chat_sessions",
                sa.Column(
                    "kind",
                    sa.String(10),
                    nullable=False,
                    server_default="chat",
                ),
            )

    if "pending_actions" not in tables:
        op.create_table(
            "pending_actions",
            sa.Column(
                "id",
                UUID(as_uuid=True),
                primary_key=True,
                server_default=sa.text("uuid_generate_v4()"),
            ),
            sa.Column("user_id", UUID(as_uuid=True), nullable=False),
            sa.Column("session_id", UUID(as_uuid=True), nullable=True),
            sa.Column("source", sa.String(10), nullable=False),
            sa.Column("tool", sa.String(200), nullable=False),
            sa.Column(
                "arguments",
                JSONB(),
                nullable=False,
                server_default=sa.text("'{}'::jsonb"),
            ),
            sa.Column("summary", sa.Text(), nullable=False),
            sa.Column(
                "status", sa.String(20), nullable=False, server_default="pending"
            ),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                nullable=False,
                server_default=sa.text("now()"),
            ),
            sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        )
    if "ix_pending_actions_user_status" not in _index_names("pending_actions"):
        op.create_index(
            "ix_pending_actions_user_status", "pending_actions", ["user_id", "status"]
        )

    if "action_log" not in tables:
        op.create_table(
            "action_log",
            sa.Column(
                "id",
                UUID(as_uuid=True),
                primary_key=True,
                server_default=sa.text("uuid_generate_v4()"),
            ),
            sa.Column("user_id", UUID(as_uuid=True), nullable=False),
            sa.Column("source", sa.String(10), nullable=False),
            sa.Column("toolkit", sa.String(100), nullable=False),
            sa.Column("tool", sa.String(200), nullable=False),
            sa.Column(
                "arguments_summary", sa.Text(), nullable=False, server_default=""
            ),
            sa.Column("outcome", sa.String(10), nullable=False),
            sa.Column("error", sa.Text(), nullable=True),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                nullable=False,
                server_default=sa.text("now()"),
            ),
        )
    if "ix_action_log_user_created" not in _index_names("action_log"):
        op.create_index(
            "ix_action_log_user_created", "action_log", ["user_id", "created_at"]
        )


def downgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    tables = set(inspector.get_table_names())

    if "action_log" in tables:
        if "ix_action_log_user_created" in _index_names("action_log"):
            op.drop_index("ix_action_log_user_created", table_name="action_log")
        op.drop_table("action_log")

    if "pending_actions" in tables:
        if "ix_pending_actions_user_status" in _index_names("pending_actions"):
            op.drop_index("ix_pending_actions_user_status", table_name="pending_actions")
        op.drop_table("pending_actions")

    if "chat_sessions" in tables:
        columns = {column["name"] for column in inspector.get_columns("chat_sessions")}
        if "kind" in columns:
            op.drop_column("chat_sessions", "kind")
