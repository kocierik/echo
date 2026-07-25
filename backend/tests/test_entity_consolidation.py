"""Unit tests for entity consolidation logic."""

from datetime import datetime, timezone


class FakeEntity:
    """Minimal entity-like object for testing merge logic."""

    def __init__(self, entity_type, name, content=None, metadata_=None):
        self.entity_type = entity_type
        self.name = name
        self.content = content
        self.metadata_ = metadata_ or {}
        self.source_transcription_id = None
        self.conversation_id = None
        self.updated_at = None


def _merge_into_existing(existing, new):
    """Inline copy of merge logic for testing without sqlalchemy dependency."""
    # Update content
    if new.content:
        if not existing.content:
            existing.content = new.content
        elif new.content != existing.content:
            if existing.entity_type == "task":
                existing.content = new.content
            elif existing.entity_type == "person":
                if new.content.lower() not in existing.content.lower():
                    existing.content = f"{existing.content}. {new.content}"
                    if len(existing.content) > 500:
                        existing.content = existing.content[-500:]
            else:
                existing.content = new.content

    # Merge metadata
    if new.metadata_:
        merged = {**existing.metadata_, **new.metadata_}
        merged = {k: v for k, v in merged.items() if v is not None}
        existing.metadata_ = merged

    # Update source reference
    if new.source_transcription_id:
        existing.source_transcription_id = new.source_transcription_id
    if new.conversation_id:
        existing.conversation_id = new.conversation_id

    # Refresh timestamp
    existing.updated_at = datetime.now(timezone.utc)


class TestMergeIntoExisting:
    def test_merge_new_content_into_empty(self):
        existing = FakeEntity("person", "Marco", content=None)
        new = FakeEntity("person", "Marco", content="Lavora in marketing")

        _merge_into_existing(existing, new)

        assert existing.content == "Lavora in marketing"

    def test_merge_person_appends_content(self):
        existing = FakeEntity("person", "Marco", content="Lavora in marketing")
        new = FakeEntity("person", "Marco", content="Ha un cane di nome Rex")

        _merge_into_existing(existing, new)

        assert "marketing" in existing.content
        assert "Rex" in existing.content

    def test_merge_person_no_duplicate_content(self):
        existing = FakeEntity("person", "Marco", content="Lavora in marketing")
        new = FakeEntity("person", "Marco", content="lavora in marketing")

        _merge_into_existing(existing, new)

        # Should not duplicate
        assert existing.content.lower().count("marketing") == 1

    def test_merge_task_replaces_content(self):
        existing = FakeEntity("task", "Comprare il latte", content="Da fare domani")
        new = FakeEntity("task", "Comprare il latte", content="Fatto oggi")

        _merge_into_existing(existing, new)

        # Task content replaced (reflects latest state)
        assert existing.content == "Fatto oggi"

    def test_merge_metadata_new_overrides(self):
        existing = FakeEntity("task", "Task A", metadata_={"done": False, "priority": "low"})
        new = FakeEntity("task", "Task A", metadata_={"done": True})

        _merge_into_existing(existing, new)

        assert existing.metadata_["done"] is True
        assert existing.metadata_["priority"] == "low"

    def test_merge_metadata_removes_none(self):
        existing = FakeEntity("person", "Marco", metadata_={"role": "dev"})
        new = FakeEntity("person", "Marco", metadata_={"role": None, "team": "alpha"})

        _merge_into_existing(existing, new)

        # None values are removed
        assert "role" not in existing.metadata_
        assert existing.metadata_["team"] == "alpha"

    def test_merge_updates_timestamp(self):
        existing = FakeEntity("person", "Marco")
        new = FakeEntity("person", "Marco", content="Nuova info")

        _merge_into_existing(existing, new)

        assert existing.updated_at is not None

    def test_merge_idea_replaces_content(self):
        existing = FakeEntity("idea", "App per la spesa", content="Vecchia descrizione")
        new = FakeEntity("idea", "App per la spesa", content="Nuova descrizione migliorata")

        _merge_into_existing(existing, new)

        assert existing.content == "Nuova descrizione migliorata"
