"""Track when a person fact was rejected.

Revision ID: 041
Revises: 040
Create Date: 2026-11-11
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect

from alembic import op

revision: str = "041"
down_revision: Union[str, None] = "040"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    tables = set(inspector.get_table_names())
    if "person_facts" not in tables:
        return

    columns = {column["name"] for column in inspector.get_columns("person_facts")}
    if "rejected_at" not in columns:
        op.add_column(
            "person_facts",
            sa.Column("rejected_at", sa.DateTime(timezone=True), nullable=True),
        )


def downgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    if "person_facts" not in set(inspector.get_table_names()):
        return

    columns = {column["name"] for column in inspector.get_columns("person_facts")}
    if "rejected_at" in columns:
        op.drop_column("person_facts", "rejected_at")
