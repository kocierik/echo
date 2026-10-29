"""The release key's signature of a firmware image, checked by the wearable.

Revision ID: 030
Revises: 029
Create Date: 2026-10-29

Firmware 0.8.0 installs an update only signed with the release key, which neither the
server nor the phone holds. Releases published before have none.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "030"
down_revision: Union[str, None] = "029"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("firmware_releases", sa.Column("signature", sa.String(128), nullable=True))


def downgrade() -> None:
    op.drop_column("firmware_releases", "signature")
