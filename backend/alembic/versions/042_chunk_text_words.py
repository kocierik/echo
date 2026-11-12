"""A passage's words, kept ready for the search by the question's own words.

Revision ID: 042
Revises: 041
Create Date: 2026-11-12

Memory search ranks passages by meaning and by the question's own words
(services/memory_retrieval.py). Reading the words out of every passage at each question
is slow; Postgres keeps them, and brings them up to date with the text.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import TSVECTOR

from alembic import op

revision: str = "042"
down_revision: Union[str, None] = "041"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    if "text_words" not in {c["name"] for c in inspector.get_columns("chunks")}:
        op.add_column(
            "chunks",
            sa.Column(
                "text_words",
                TSVECTOR(),
                sa.Computed("to_tsvector('simple', text)", persisted=True),
                nullable=True,
            ),
        )
    if "idx_chunks_text_words" not in {i["name"] for i in inspector.get_indexes("chunks")}:
        op.create_index(
            "idx_chunks_text_words", "chunks", ["text_words"], postgresql_using="gin"
        )


def downgrade() -> None:
    op.drop_index("idx_chunks_text_words", table_name="chunks")
    op.drop_column("chunks", "text_words")
