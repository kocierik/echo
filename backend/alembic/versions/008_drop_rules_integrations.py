"""Drop the rules and integrations tables (replaced by Composio actions).

Revision ID: 008
Revises: 007
Create Date: 2026-10-13

"""
from typing import Sequence, Union

from alembic import op
from sqlalchemy import inspect as sa_inspect

revision: str = "008"
down_revision: Union[str, None] = "007"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    tables = set(sa_inspect(op.get_bind()).get_table_names())
    for table_name in ("rules", "integrations"):
        if table_name in tables:
            op.drop_table(table_name)


def downgrade() -> None:
    """No-op: the dropped rules and integrations data is not restored."""
