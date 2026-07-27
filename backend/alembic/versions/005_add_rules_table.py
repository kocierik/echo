"""Add rules table for automation engine.

Revision ID: 005
Revises: 004
Create Date: 2026-07-27

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "005"
down_revision: Union[str, None] = "004"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()
    inspector = sa_inspect(conn)
    tables = inspector.get_table_names()

    if "rules" not in tables:
        op.create_table(
            "rules",
            sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("uuid_generate_v4()")),
            sa.Column("user_id", UUID(as_uuid=True), nullable=False),
            sa.Column("name", sa.String(200), nullable=False),
            sa.Column("description", sa.Text(), nullable=True),
            sa.Column("enabled", sa.Boolean(), nullable=False, server_default="true"),
            sa.Column("conditions", JSONB(), nullable=False, server_default="{}"),
            sa.Column("actions", JSONB(), nullable=False, server_default="[]"),
            sa.Column("trigger_count", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("last_triggered_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        )
        op.create_index("idx_rules_user", "rules", ["user_id"])
        op.create_index("idx_rules_enabled", "rules", ["user_id", "enabled"], postgresql_where=sa.text("enabled = true"))


def downgrade() -> None:
    conn = op.get_bind()
    inspector = sa_inspect(conn)
    tables = inspector.get_table_names()

    if "rules" in tables:
        op.drop_index("idx_rules_enabled", table_name="rules")
        op.drop_index("idx_rules_user", table_name="rules")
        op.drop_table("rules")
