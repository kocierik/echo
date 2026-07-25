"""Add audio_hash column to segments for idempotent ingest.

Revision ID: 002
Revises: 001
Create Date: 2026-07-25

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "002"
down_revision: Union[str, None] = "001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "segments",
        sa.Column(
            "audio_hash",
            sa.String(64),
            nullable=True,
            unique=True,
            comment="SHA-256 of audio content + recorded_at for idempotency",
        ),
    )
    op.create_index("idx_segments_audio_hash", "segments", ["audio_hash"], unique=True)


def downgrade() -> None:
    op.drop_index("idx_segments_audio_hash", table_name="segments")
    op.drop_column("segments", "audio_hash")
