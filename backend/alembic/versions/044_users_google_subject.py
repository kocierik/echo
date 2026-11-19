"""Sign in with Google: the Google account behind a user.

Revision ID: 044
Revises: 043
Create Date: 2026-11-19

Google's stable id for the person ("sub" in the ID token). Matched first on every Google
sign-in, so a changed Gmail address still finds the same account.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect

from alembic import op

revision: str = "044"
down_revision: Union[str, None] = "043"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    if "google_subject" not in {c["name"] for c in inspector.get_columns("users")}:
        op.add_column("users", sa.Column("google_subject", sa.String(255), nullable=True))
        op.create_index("ix_users_google_subject", "users", ["google_subject"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_users_google_subject", table_name="users")
    op.drop_column("users", "google_subject")
