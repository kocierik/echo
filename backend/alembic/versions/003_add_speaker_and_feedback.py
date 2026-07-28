"""Add speaker detection and query feedback tables.

Revision ID: 003
Revises: 002
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "003"
down_revision: Union[str, None] = "002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Speaker detection columns
    op.add_column("segments", sa.Column("audio_energy", sa.Integer(), nullable=True))
    op.add_column("segments", sa.Column("speaker", sa.String(10), nullable=True, server_default="unknown"))

    # Query feedback table
    op.create_table(
        "query_feedback",
        sa.Column("id", sa.dialects.postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("uuid_generate_v4()")),
        sa.Column("user_id", sa.dialects.postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("session_id", sa.dialects.postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("message_index", sa.Integer(), nullable=False),
        sa.Column("rating", sa.String(10), nullable=False),
        sa.Column("comment", sa.Text(), nullable=True),
        sa.Column("source_chunk_ids", sa.dialects.postgresql.JSONB(), nullable=False, server_default="[]"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.create_index("idx_feedback_user", "query_feedback", ["user_id", "created_at"])
    op.create_index("idx_feedback_chunks", "query_feedback", ["source_chunk_ids"], postgresql_using="gin")


def downgrade() -> None:
    op.drop_table("query_feedback")
    op.drop_column("segments", "speaker")
    op.drop_column("segments", "audio_energy")
"""Add speaker detection columns and query feedback table.

Revision ID: 003
Revises: 002
Create Date: 2026-07-25

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "003"
down_revision: Union[str, None] = "002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()
    inspector = sa_inspect(conn)

    # Speaker detection columns on segments
    columns = [c["name"] for c in inspector.get_columns("segments")]

    if "audio_energy" not in columns:
        op.add_column("segments", sa.Column("audio_energy", sa.Integer(), nullable=True))

    if "speaker" not in columns:
        op.add_column(
            "segments",
            sa.Column("speaker", sa.String(10), nullable=True, server_default="unknown"),
        )

    # Query feedback table
    tables = inspector.get_table_names()
    if "query_feedback" not in tables:
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
    conn = op.get_bind()
    inspector = sa_inspect(conn)
    tables = inspector.get_table_names()

    if "query_feedback" in tables:
        op.drop_index("idx_feedback_chunks", table_name="query_feedback")
        op.drop_index("idx_feedback_user", table_name="query_feedback")
        op.drop_table("query_feedback")

    columns = [c["name"] for c in inspector.get_columns("segments")]
    if "speaker" in columns:
        op.drop_column("segments", "speaker")
    if "audio_energy" in columns:
        op.drop_column("segments", "audio_energy")
