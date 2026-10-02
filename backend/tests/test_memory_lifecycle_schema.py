"""Metadata contracts for memory lifecycle ownership and deletion."""

from pathlib import Path

from app.models import (
    Base,
    Chunk,
    Conversation,
    Entity,
    Segment,
    Transcription,
    TranscriptionEdit,
)


def _foreign_key_ondelete(model, column_name: str) -> str | None:
    column = model.__table__.c[column_name]
    return next(iter(column.foreign_keys)).ondelete


def test_transcription_edit_is_registered() -> None:
    table = Base.metadata.tables["transcription_edits"]

    assert set(table.columns) == {
        "id",
        "transcription_id",
        "user_id",
        "old_text",
        "new_text",
        "old_speaker_label",
        "new_speaker_label",
        "created_at",
    }


def test_transcription_speaker_label_lifecycle_contract() -> None:
    column = Transcription.__table__.c.speaker_label
    migration_source = (
        Path(__file__).parents[1] / "alembic" / "versions" / "006_memory_lifecycle.py"
    ).read_text(encoding="utf-8")
    normalized_migration = " ".join(migration_source.split())

    assert column.nullable is True
    assert column.type.length == 10
    assert 'op.add_column( "transcriptions", sa.Column("speaker_label"' in normalized_migration
    assert 'op.drop_column("transcriptions", "speaker_label")' in migration_source


def test_segment_audio_storage_is_nullable_with_reversible_migration() -> None:
    audio_path = Segment.__table__.c.audio_path
    audio_size_bytes = Segment.__table__.c.audio_size_bytes
    migration_source = (
        Path(__file__).parents[1] / "alembic" / "versions" / "006_memory_lifecycle.py"
    ).read_text(encoding="utf-8")
    normalized_migration = " ".join(migration_source.split())

    assert audio_path.nullable is True
    assert audio_size_bytes.nullable is True
    assert normalized_migration.count('op.alter_column( "segments", "audio_path"') == 2
    assert normalized_migration.count('op.alter_column( "segments", "audio_size_bytes"') == 2
    assert "existing_type=sa.Text()" in migration_source
    assert "existing_type=sa.Integer()" in migration_source
    assert "UPDATE segments SET audio_path = '' WHERE audio_path IS NULL" in migration_source
    assert (
        "UPDATE segments SET audio_size_bytes = 0 "
        '"\n                    "WHERE audio_size_bytes IS NULL'
    ) in migration_source


def test_conversation_children_use_database_cascade() -> None:
    assert Conversation.segments.property.passive_deletes is True
    assert Conversation.entities.property.passive_deletes is True
    assert Conversation.chunks.property.passive_deletes is True

    assert _foreign_key_ondelete(Segment, "conversation_id") == "CASCADE"
    assert _foreign_key_ondelete(Entity, "conversation_id") == "CASCADE"
    assert _foreign_key_ondelete(Chunk, "conversation_id") == "CASCADE"


def test_transcription_edits_use_database_cascade() -> None:
    assert Segment.transcription.property.passive_deletes is True
    assert Transcription.edits.property.passive_deletes is True
    assert "delete-orphan" in Transcription.edits.property.cascade
    assert _foreign_key_ondelete(TranscriptionEdit, "transcription_id") == "CASCADE"