"""Add speaker detection columns and query feedback table.

Revision ID: 003
Revises: 002
Create Date: 2026-07-25

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "003"
down_revision: Union[str, None] = "002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Speaker detection columns on segments
    op.add_column("segments", sa.Column("audio_energy", sa.Integer(), nullable=True))
    op.add_column(
        "segments",
        sa.Column("speaker", sa.String(10), nullable=True, server_default="unknown"),
    )

    # Query feedback table
    op.create_table(
        "query_feedback",
        sa.Column(
            "id", UUID(as_uuid=True), primary_key=True,
            server_default=sa.text("uuid_generate_v4()"),
        ),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("session_id", UUID(as_uuid=True), nullable=False),
        sa.Column("message_index", sa.Integer(), nullable=False),
        sa.Column("rating", sa.String(10), nullable=False),
        sa.Column("comment", sa.Text(), nullable=True),
        sa.Column("source_chunk_ids", JSONB(), nullable=False, server_default="[]"),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False,
            server_default=sa.text("now()"),
        ),
    )
    op.create_index("idx_feedback_user", "query_feedback", ["user_id", "created_at"])
    op.create_index(
        "idx_feedback_chunks", "query_feedback", ["source_chunk_ids"],
        postgresql_using="gin",
    )


def downgrade() -> None:
    op.drop_index("idx_feedback_chunks", table_name="query_feedback")
    op.drop_index("idx_feedback_user", table_name="query_feedback")
    op.drop_table("query_feedback")
    op.drop_column("segments", "speaker")
    op.drop_column("segments", "audio_energy")
