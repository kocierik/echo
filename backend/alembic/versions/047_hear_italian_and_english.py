"""Every account hears the other of Italian and English by default.

Revision ID: 047
Revises: 046
Create Date: 2026-11-23

A segment in a language the account did not list was transcribed as if it were the main
one: English speech written as Italian words. New accounts now hear the other of the two
(models/user.py); the accounts that chose no other language get it too. One that later
removes it keeps it removed: this runs once.
"""

from typing import Sequence, Union

from alembic import op

revision: str = "047"
down_revision: Union[str, None] = "046"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "UPDATE users SET other_languages = CASE WHEN language = 'en' "
        "THEN '[\"it\"]'::jsonb ELSE '[\"en\"]'::jsonb END "
        "WHERE other_languages = '[]'::jsonb"
    )


def downgrade() -> None:
    pass  # which accounts had chosen it themselves is not known
