"""The other languages a user hears, and translations of transcript lines.

Revision ID: 027
Revises: 026
Create Date: 2026-10-28

Existing accounts hear no other language: transcription stays in their one language.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "027"
down_revision: Union[str, None] = "026"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "users", sa.Column("other_languages", JSONB, nullable=False, server_default="[]")
    )
    op.create_table(
        "transcription_translations",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("transcription_id", UUID(as_uuid=True), nullable=False),
        sa.Column("language", sa.String(10), nullable=False),
        sa.Column("text", sa.Text, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["transcription_id"],
            ["transcriptions.id"],
            name="fk_transcription_translations_transcription",
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint(
            "transcription_id", "language", name="uq_transcription_translations_language"
        ),
    )


def downgrade() -> None:
    op.drop_table("transcription_translations")
    op.drop_column("users", "other_languages")
