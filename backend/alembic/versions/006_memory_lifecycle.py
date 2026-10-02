"""Add memory lifecycle audit storage and cascade constraints.

Revision ID: 006
Revises: 005
Create Date: 2026-10-02

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import UUID

revision: str = "006"
down_revision: Union[str, None] = "005"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _ondelete(foreign_key: dict) -> str | None:
    value = foreign_key.get("options", {}).get("ondelete")
    return value.upper() if value else None


def _ensure_foreign_key(
    table_name: str,
    column_name: str,
    referred_table: str,
    constraint_name: str,
    ondelete: str | None,
) -> None:
    conn = op.get_bind()
    inspector = sa_inspect(conn)
    tables = set(inspector.get_table_names())

    if table_name not in tables:
        return
    if referred_table not in tables:
        raise RuntimeError(
            f"Cannot configure {table_name}.{column_name}: "
            f"referenced table {referred_table} does not exist"
        )

    columns = {column["name"] for column in inspector.get_columns(table_name)}
    if column_name not in columns:
        raise RuntimeError(f"Cannot configure missing column {table_name}.{column_name}")

    target_foreign_keys = [
        foreign_key
        for foreign_key in inspector.get_foreign_keys(table_name)
        if foreign_key["constrained_columns"] == [column_name]
        and foreign_key["referred_table"] == referred_table
        and foreign_key["referred_columns"] == ["id"]
    ]

    if len(target_foreign_keys) == 1 and _ondelete(target_foreign_keys[0]) == ondelete:
        return

    for foreign_key in target_foreign_keys:
        if not foreign_key["name"]:
            raise RuntimeError(
                f"Cannot replace unnamed foreign key on {table_name}.{column_name}"
            )
        op.drop_constraint(foreign_key["name"], table_name, type_="foreignkey")

    op.create_foreign_key(
        constraint_name,
        table_name,
        referred_table,
        [column_name],
        ["id"],
        ondelete=ondelete,
    )


def _has_index(table_name: str, column_name: str) -> bool:
    inspector = sa_inspect(op.get_bind())
    return any(
        index["column_names"] == [column_name]
        for index in inspector.get_indexes(table_name)
    )


def upgrade() -> None:
    conn = op.get_bind()
    inspector = sa_inspect(conn)
    tables = set(inspector.get_table_names())

    if "segments" in tables:
        segment_columns = {
            column["name"] for column in inspector.get_columns("segments")
        }
        if "audio_path" in segment_columns:
            op.alter_column(
                "segments",
                "audio_path",
                existing_type=sa.Text(),
                nullable=True,
            )
        if "audio_size_bytes" in segment_columns:
            op.alter_column(
                "segments",
                "audio_size_bytes",
                existing_type=sa.Integer(),
                nullable=True,
            )

    if "transcriptions" in tables:
        transcription_columns = {
            column["name"] for column in inspector.get_columns("transcriptions")
        }
        if "speaker_label" not in transcription_columns:
            op.add_column(
                "transcriptions",
                sa.Column("speaker_label", sa.String(10), nullable=True),
            )

    if "transcription_edits" not in tables:
        if "transcriptions" not in tables:
            raise RuntimeError(
                "Cannot create transcription_edits: transcriptions table does not exist"
            )
        op.create_table(
            "transcription_edits",
            sa.Column(
                "id",
                UUID(as_uuid=True),
                primary_key=True,
                server_default=sa.text("uuid_generate_v4()"),
            ),
            sa.Column("transcription_id", UUID(as_uuid=True), nullable=False),
            sa.Column("user_id", UUID(as_uuid=True), nullable=False),
            sa.Column("old_text", sa.Text(), nullable=False),
            sa.Column("new_text", sa.Text(), nullable=False),
            sa.Column("old_speaker_label", sa.String(10), nullable=True),
            sa.Column("new_speaker_label", sa.String(10), nullable=True),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                nullable=False,
                server_default=sa.text("now()"),
            ),
            sa.ForeignKeyConstraint(
                ["transcription_id"],
                ["transcriptions.id"],
                name="fk_transcription_edits_transcription_id_transcriptions",
                ondelete="CASCADE",
            ),
        )

    _ensure_foreign_key(
        "transcription_edits",
        "transcription_id",
        "transcriptions",
        "fk_transcription_edits_transcription_id_transcriptions",
        "CASCADE",
    )

    if not _has_index("transcription_edits", "transcription_id"):
        op.create_index(
            "ix_transcription_edits_transcription_id",
            "transcription_edits",
            ["transcription_id"],
        )
    if not _has_index("transcription_edits", "user_id"):
        op.create_index(
            "ix_transcription_edits_user_id",
            "transcription_edits",
            ["user_id"],
        )

    _ensure_foreign_key(
        "segments",
        "conversation_id",
        "conversations",
        "fk_segments_conversation_id_conversations",
        "CASCADE",
    )
    _ensure_foreign_key(
        "entities",
        "conversation_id",
        "conversations",
        "fk_entities_conversation_id_conversations",
        "CASCADE",
    )


def downgrade() -> None:
    conn = op.get_bind()
    inspector = sa_inspect(conn)
    if "segments" in inspector.get_table_names():
        segment_columns = {
            column["name"] for column in inspector.get_columns("segments")
        }
        if "audio_path" in segment_columns:
            conn.execute(
                sa.text("UPDATE segments SET audio_path = '' WHERE audio_path IS NULL")
            )
            op.alter_column(
                "segments",
                "audio_path",
                existing_type=sa.Text(),
                nullable=False,
            )
        if "audio_size_bytes" in segment_columns:
            conn.execute(
                sa.text(
                    "UPDATE segments SET audio_size_bytes = 0 "
                    "WHERE audio_size_bytes IS NULL"
                )
            )
            op.alter_column(
                "segments",
                "audio_size_bytes",
                existing_type=sa.Integer(),
                nullable=False,
            )

    _ensure_foreign_key(
        "segments",
        "conversation_id",
        "conversations",
        "fk_segments_conversation_id_conversations",
        None,
    )
    _ensure_foreign_key(
        "entities",
        "conversation_id",
        "conversations",
        "fk_entities_conversation_id_conversations",
        "SET NULL",
    )

    inspector = sa_inspect(conn)
    if "transcription_edits" in inspector.get_table_names():
        index_names = {
            index["name"] for index in inspector.get_indexes("transcription_edits")
        }
        if "ix_transcription_edits_user_id" in index_names:
            op.drop_index("ix_transcription_edits_user_id", table_name="transcription_edits")
        if "ix_transcription_edits_transcription_id" in index_names:
            op.drop_index(
                "ix_transcription_edits_transcription_id",
                table_name="transcription_edits",
            )
        op.drop_table("transcription_edits")

    inspector = sa_inspect(op.get_bind())
    if "transcriptions" in inspector.get_table_names():
        transcription_columns = {
            column["name"] for column in inspector.get_columns("transcriptions")
        }
        if "speaker_label" in transcription_columns:
            op.drop_column("transcriptions", "speaker_label")