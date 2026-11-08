"""Several voices in one segment: its turns, who said what.

Revision ID: 038
Revises: 037
Create Date: 2026-11-08

A segment lasts up to 25 s and several people can speak in it. Once the conversation is
closed it is transcribed again with each word's speaker (services/retranscription.py);
a segment where more than one spoke keeps its turns.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "038"
down_revision: Union[str, None] = "037"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    columns = {c["name"] for c in sa_inspect(op.get_bind()).get_columns("transcriptions")}
    if "turns" not in columns:
        op.add_column("transcriptions", sa.Column("turns", JSONB(), nullable=True))


def downgrade() -> None:
    op.drop_column("transcriptions", "turns")
