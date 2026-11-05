"""Documents indexed again, in shorter passages each embedded under the document's name.

Revision ID: 032
Revises: 031
Create Date: 2026-11-05

A whole CV was one passage: a question about part of it (where you studied, "my CV")
was too far from all of it to be found. The worker reads each ready document's text
again, a few minutes after the deploy; it shows "processing" until then.
"""

from typing import Sequence, Union

from alembic import op

revision: str = "032"
down_revision: Union[str, None] = "031"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Claimed 12 minutes ago: a claim is taken again after 15 (workers/documents.py STALE),
    # so in about 3 minutes, by the worker the deploy restarts, never by the one still
    # running the old passages while the migration runs
    op.execute(
        "UPDATE documents SET status = 'processing', "
        "claimed_at = now() - interval '12 minutes' WHERE status = 'ready'"
    )


def downgrade() -> None:
    # The passages are only shorter: nothing to undo
    pass
