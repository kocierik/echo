"""Entity consolidation: update existing entities with new information.

When the user mentions something already known (e.g., a person whose role
changed, a task that was completed), we should UPDATE the existing entity
rather than create a duplicate. This avoids contradictory information in memory.

Strategy:
1. For each newly extracted entity, check if a matching entity already exists
2. If yes (same type + high name similarity), merge the new info into existing
3. If no, create the new entity as usual
"""

import logging
import uuid
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

    from app.models.entity import Entity

from app.services.deduplication import name_similarity

logger = logging.getLogger(__name__)

# Minimum similarity to consider an entity as "the same"
CONSOLIDATION_THRESHOLD = 0.85


async def consolidate_entities(
    db: "AsyncSession",
    new_entities: list["Entity"],
    user_id: uuid.UUID,
) -> list["Entity"]:
    """Consolidate new entities with existing ones.

    For each new entity:
    - If a matching existing entity is found (same type, similar name):
      update the existing one with new content/metadata, return None for that slot.
    - If no match: return the new entity for insertion.

    Args:
        db: Database session.
        new_entities: Entities just extracted from a transcription.
        user_id: Owner user ID.

    Returns:
        List of entities that are truly NEW and should be inserted.
        (Existing entities are updated in-place via the session.)
    """
    from sqlalchemy import select

    from app.models.entity import Entity

    if not new_entities:
        return []

    truly_new: list[Entity] = []

    for new_entity in new_entities:
        # Look for existing entity of the same type with similar name
        existing_query = (
            select(Entity)
            .where(Entity.user_id == user_id)
            .where(Entity.entity_type == new_entity.entity_type)
            .order_by(Entity.updated_at.desc())
            .limit(50)
        )
        result = await db.execute(existing_query)
        candidates = result.scalars().all()

        best_match: Entity | None = None
        best_similarity = 0.0

        for candidate in candidates:
            sim = name_similarity(candidate.name, new_entity.name)
            if sim > best_similarity and sim >= CONSOLIDATION_THRESHOLD:
                best_similarity = sim
                best_match = candidate

        if best_match is not None:
            # Update existing entity with new information
            _merge_into_existing(best_match, new_entity)
            logger.debug(
                f"[Consolidation] Updated existing '{best_match.name}' "
                f"with new info (sim={best_similarity:.2f})"
            )
        else:
            truly_new.append(new_entity)

    return truly_new


def _merge_into_existing(existing: "Entity", new: "Entity") -> None:
    """Merge new entity information into an existing one.

    Rules:
    - New content REPLACES old content if new is more specific/recent
    - Metadata is merged (new values override old for same keys)
    - updated_at is refreshed
    - source references are kept from new (latest transcription context)
    """
    from datetime import datetime, timezone

    # Update content: append if different and both non-empty, replace if new is longer
    if new.content:
        if not existing.content:
            existing.content = new.content
        elif new.content != existing.content:
            # For tasks: new content likely reflects current state (e.g., "completato")
            if existing.entity_type == "task":
                existing.content = new.content
            # For people: accumulate knowledge
            elif existing.entity_type == "person":
                # Avoid duplicating the same info
                if new.content.lower() not in existing.content.lower():
                    existing.content = f"{existing.content}. {new.content}"
                    # Keep it concise
                    if len(existing.content) > 500:
                        existing.content = existing.content[-500:]
            else:
                # For ideas/events/notes: latest info wins
                existing.content = new.content

    # Merge metadata (new values take priority)
    if new.metadata_:
        merged = {**existing.metadata_, **new.metadata_}
        # Remove None values
        merged = {k: v for k, v in merged.items() if v is not None}
        existing.metadata_ = merged

    # Update source reference to latest transcription
    if new.source_transcription_id:
        existing.source_transcription_id = new.source_transcription_id
    if new.conversation_id:
        existing.conversation_id = new.conversation_id

    # Refresh timestamp
    existing.updated_at = datetime.now(timezone.utc)
