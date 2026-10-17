"""Tool calls by connected apps over MCP, per key.

Revision ID: 019
Revises: 018
Create Date: 2026-10-16
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "019"
down_revision: Union[str, None] = "018"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "mcp_calls",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "api_key_id", UUID(as_uuid=True),
            sa.ForeignKey("api_keys.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("tool", sa.String(40), nullable=False),
        sa.Column("summary", sa.String(200), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_mcp_calls_api_key_id", "mcp_calls", ["api_key_id"])


def downgrade() -> None:
    op.drop_index("ix_mcp_calls_api_key_id", table_name="mcp_calls")
    op.drop_table("mcp_calls")
