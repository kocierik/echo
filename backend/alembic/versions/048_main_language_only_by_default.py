"""Back to the main language only, undoing 047's default.

Revision ID: 048
Revises: 047
Create Date: 2026-11-28

Heard with the other of Italian and English, Deepgram's multilingual mode wrote Italian as
Croatian and Persian on the pendant's short segments, and detection between the two left
some Italian segments empty. The accounts 047 gave the other language to (exactly the
other of Italian and English) go back to none; English is still a choice in Account → Language.
Accounts that had chosen it themselves before 047 lose it too: few beta accounts, told.
"""

from typing import Sequence, Union

from alembic import op

revision: str = "048"
down_revision: Union[str, None] = "047"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "UPDATE users SET other_languages = '[]'::jsonb WHERE "
        "(language <> 'en' AND other_languages = '[\"en\"]'::jsonb) OR "
        "(language = 'en' AND other_languages = '[\"it\"]'::jsonb)"
    )


def downgrade() -> None:
    pass  # 047 gave the default once; nothing to restore
