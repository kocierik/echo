"""Make segment idempotency per user and recover interrupted transcriptions.

Revision ID: 039
Revises: 038
Create Date: 2026-11-10
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect

from alembic import op

revision: str = "039"
down_revision: Union[str, None] = "038"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    conn = op.get_bind()
    inspector = sa_inspect(conn)
    columns = {column["name"] for column in inspector.get_columns("segments")}
    indexes = {index["name"] for index in inspector.get_indexes("segments")}

    if "transcription_started_at" not in columns:
        op.add_column(
            "segments",
            sa.Column("transcription_started_at", sa.DateTime(timezone=True), nullable=True),
        )
    # Older workers wrote "processing" without a timestamp; make those claims recoverable.
    op.execute(
        "UPDATE segments SET transcription_started_at = now() - INTERVAL '16 minutes' "
        "WHERE transcription_status = 'processing' AND transcription_started_at IS NULL"
    )

    for legacy_index in ("idx_segments_audio_hash", "ix_segments_audio_hash"):
        if legacy_index in indexes:
            op.drop_index(legacy_index, table_name="segments")

    indexes = {index["name"] for index in sa_inspect(conn).get_indexes("segments")}
    if "idx_segments_user_audio_hash" not in indexes:
        op.create_index(
            "idx_segments_user_audio_hash",
            "segments",
            ["user_id", "audio_hash"],
            unique=True,
        )


def downgrade() -> None:
    conn = op.get_bind()
    indexes = {index["name"] for index in sa_inspect(conn).get_indexes("segments")}

    if "idx_segments_user_audio_hash" in indexes:
        op.drop_index("idx_segments_user_audio_hash", table_name="segments")
    for legacy_index in ("idx_segments_audio_hash", "ix_segments_audio_hash"):
        if legacy_index in indexes:
            op.drop_index(legacy_index, table_name="segments")
    op.create_index("idx_segments_audio_hash", "segments", ["audio_hash"], unique=True)

    columns = {column["name"] for column in sa_inspect(conn).get_columns("segments")}
    if "transcription_started_at" in columns:
        op.drop_column("segments", "transcription_started_at")
