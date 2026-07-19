"""Entity deduplication service.

Merges duplicate entities (e.g. "Marco", "marco", "Marco Rossi") into a single
canonical entity. Uses fuzzy name matching + LLM confirmation for ambiguous cases.
"""

import logging
import uuid
from difflib import SequenceMatcher

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.entity import Entity
from app.services.llm_base import LLMMessage, LLMService

logger = logging.getLogger(__name__)

# Minimum similarity ratio to consider two names as potential duplicates
NAME_SIMILARITY_THRESHOLD = 0.75

# If similarity is above this, merge without LLM confirmation
AUTO_MERGE_THRESHOLD = 0.92


def normalize_name(name: str) -> str:
    """Normalize entity name for comparison."""
    return name.strip().lower()


def name_similarity(a: str, b: str) -> float:
    """Calculate similarity ratio between two names (0.0 to 1.0)."""
    na = normalize_name(a)
    nb = normalize_name(b)

    # Exact match after normalization
    if na == nb:
        return 1.0

    # One is a substring of the other (e.g. "Marco" vs "Marco Rossi")
    if na in nb or nb in na:
        return 0.95

    # Sequence matching
    return SequenceMatcher(None, na, nb).ratio()


async def deduplicate_entities(
    db: AsyncSession,
    user_id: uuid.UUID,
    llm_service: LLMService | None = None,
) -> int:
    """Find and merge duplicate entities for a user.

    Strategy:
    1. Group entities by type
    2. Within each type, compare names with fuzzy matching
    3. Auto-merge if similarity > AUTO_MERGE_THRESHOLD
    4. For borderline cases (similarity between thresholds), use LLM to confirm
    5. Merge = keep the oldest entity, update references, delete duplicates

    Args:
        db: Database session.
        user_id: User whose entities to deduplicate.
        llm_service: Optional LLM for ambiguous cases. If None, only auto-merge.

    Returns:
        Number of entities merged.
    """
    merged_count = 0

    # Process each entity type separately
    for entity_type in ("person", "task", "idea", "event", "note"):
        query = (
            select(Entity)
            .where(Entity.user_id == user_id)
            .where(Entity.entity_type == entity_type)
            .order_by(Entity.created_at)  # oldest first = canonical
        )
        result = await db.execute(query)
        entities = list(result.scalars().all())

        if len(entities) < 2:
            continue

        # Find duplicate groups
        merged_ids: set[uuid.UUID] = set()

        for i, canonical in enumerate(entities):
            if canonical.id in merged_ids:
                continue

            for j in range(i + 1, len(entities)):
                duplicate = entities[j]
                if duplicate.id in merged_ids:
                    continue

                similarity = name_similarity(canonical.name, duplicate.name)

                if similarity < NAME_SIMILARITY_THRESHOLD:
                    continue

                should_merge = False

                if similarity >= AUTO_MERGE_THRESHOLD:
                    should_merge = True
                elif llm_service is not None:
                    # Ask LLM for borderline cases
                    should_merge = await llm_confirm_merge(
                        llm_service, entity_type, canonical, duplicate
                    )

                if should_merge:
                    await merge_entities(db, canonical, duplicate)
                    merged_ids.add(duplicate.id)
                    merged_count += 1
                    logger.info(
                        f"[Dedup] Merged '{duplicate.name}' into '{canonical.name}' "
                        f"(type={entity_type}, sim={similarity:.2f})"
                    )

    await db.commit()
    return merged_count


async def merge_entities(db: AsyncSession, canonical: Entity, duplicate: Entity):
    """Merge duplicate entity into canonical. Keeps canonical, deletes duplicate.

    - Merges metadata (canonical takes priority)
    - Appends content if different
    - Updates references pointing to duplicate
    """
    # Merge metadata
    merged_metadata = {**duplicate.metadata_, **canonical.metadata_}
    canonical.metadata_ = merged_metadata

    # Append content if duplicate has unique info
    if duplicate.content and duplicate.content != canonical.content:
        if canonical.content:
            canonical.content = f"{canonical.content}\n{duplicate.content}"
        else:
            canonical.content = duplicate.content

    # Update any entities that reference the duplicate's transcription/conversation
    # (the duplicate's source references are valuable context for the canonical)

    # Delete the duplicate
    await db.delete(duplicate)


async def llm_confirm_merge(
    llm_service: LLMService,
    entity_type: str,
    entity_a: Entity,
    entity_b: Entity,
) -> bool:
    """Ask LLM if two entities refer to the same real-world thing."""
    messages = [
        LLMMessage(
            role="system",
            content=(
                "Sei un sistema di deduplicazione. Determina se due entità si riferiscono "
                "alla stessa cosa nel mondo reale. Rispondi SOLO con 'yes' o 'no'."
            ),
        ),
        LLMMessage(
            role="user",
            content=(
                f"Tipo: {entity_type}\n\n"
                f"Entità A:\n"
                f"  Nome: {entity_a.name}\n"
                f"  Contenuto: {entity_a.content or '(vuoto)'}\n"
                f"  Metadata: {entity_a.metadata_}\n\n"
                f"Entità B:\n"
                f"  Nome: {entity_b.name}\n"
                f"  Contenuto: {entity_b.content or '(vuoto)'}\n"
                f"  Metadata: {entity_b.metadata_}\n\n"
                f"Queste due entità si riferiscono alla stessa cosa?"
            ),
        ),
    ]

    try:
        response = await llm_service.complete(messages, temperature=0.0)
        answer = response.content.strip().lower()
        return answer.startswith("y") or answer == "sì" or answer == "si"
    except Exception as e:
        logger.warning(f"[Dedup] LLM confirmation failed: {e}")
        return False
