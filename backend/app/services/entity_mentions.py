"""Where each entity was mentioned: one EntityMention per entity and conversation.

Entities are consolidated across conversations, so the entity row alone cannot say
which conversations a person or task came up in. Every write path keeps mentions
in step: analysis records them, merges move them, and a conversation that is
deleted or reanalysed releases the entities also mentioned elsewhere.
"""

import uuid

from sqlalchemy import delete, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.entity_mention import EntityMention


async def record_mentions(db: AsyncSession, entities: list[Entity]) -> None:
    """Record that each (flushed) entity was mentioned in its current conversation.

    The latest sentence wins as the mention's source for that conversation.
    """
    rows = {
        (entity.id, entity.conversation_id): entity.source_transcription_id
        for entity in entities
        if entity.id is not None and entity.conversation_id is not None
    }
    if not rows:
        return
    statement = insert(EntityMention).values(
        [
            {
                "id": uuid.uuid4(),
                "entity_id": entity_id,
                "conversation_id": conversation_id,
                "transcription_id": transcription_id,
            }
            for (entity_id, conversation_id), transcription_id in rows.items()
        ]
    )
    await db.execute(
        statement.on_conflict_do_update(
            index_elements=["entity_id", "conversation_id"],
            set_={"transcription_id": statement.excluded.transcription_id},
        )
    )


async def move_mentions(db: AsyncSession, source_id: uuid.UUID, target_id: uuid.UUID) -> None:
    """Give the mentions of `source` (about to be merged away) to `target`."""
    already = select(EntityMention.conversation_id).where(EntityMention.entity_id == target_id)
    await db.execute(
        delete(EntityMention)
        .where(EntityMention.entity_id == source_id)
        .where(EntityMention.conversation_id.in_(already))
    )
    await db.execute(
        update(EntityMention)
        .where(EntityMention.entity_id == source_id)
        .values(entity_id=target_id)
    )


async def release_conversation(db: AsyncSession, conversation_id: uuid.UUID) -> None:
    """Detach a conversation about to be deleted or reanalysed from its entities.

    An entity pointing at it but also mentioned in another conversation moves to the
    most recent of those, so it survives; the conversation's own mentions are
    removed. Entities mentioned only here keep pointing at it (and go with it).
    """
    pointing = (
        await db.execute(
            select(Entity.id).where(Entity.conversation_id == conversation_id)
        )
    ).scalars().all()
    for entity_id in pointing:
        latest_elsewhere = (
            await db.execute(
                select(EntityMention.conversation_id, EntityMention.transcription_id)
                .join(Conversation, Conversation.id == EntityMention.conversation_id)
                .where(EntityMention.entity_id == entity_id)
                .where(EntityMention.conversation_id != conversation_id)
                .order_by(Conversation.started_at.desc())
                .limit(1)
            )
        ).first()
        if latest_elsewhere is not None:
            await db.execute(
                update(Entity)
                .where(Entity.id == entity_id)
                .values(
                    conversation_id=latest_elsewhere.conversation_id,
                    source_transcription_id=latest_elsewhere.transcription_id,
                )
            )
    await db.execute(
        delete(EntityMention).where(EntityMention.conversation_id == conversation_id)
    )
