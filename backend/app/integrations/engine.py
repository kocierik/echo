"""Integration automation engine.

After entities are extracted, checks for active integrations and triggers the
matching provider action. HTTP clients live in app.integrations.clients and
are shared with the rules engine; Google Calendar goes through the calendar
service, which refreshes and stores the OAuth token.
"""

import logging
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.clients import (
    create_notion_page,
    create_todoist_task,
    send_slack_message,
    send_telegram_message,
)
from app.models.entity import Entity
from app.models.integration import Integration
from app.services.calendar_service import create_event, event_schedule_from_metadata

logger = logging.getLogger(__name__)


async def trigger_integrations(db: AsyncSession, user_id: uuid.UUID, entity: Entity):
    """Check active integrations and trigger for this entity type.

    Args:
        db: Database session.
        user_id: Owner user ID.
        entity: The newly extracted entity.
    """
    # Find active integrations that match this entity type
    result = await db.execute(
        select(Integration)
        .where(Integration.user_id == user_id)
        .where(Integration.enabled.is_(True))
        .where(Integration.entity_types.any(entity.entity_type))
    )
    integrations = result.scalars().all()

    for integration in integrations:
        try:
            await _execute_integration(db, user_id, integration, entity)
        except Exception as e:
            logger.error(
                f"[Integration] Failed to execute {integration.provider} "
                f"for entity '{entity.name}': {e}"
            )


async def _execute_integration(
    db: AsyncSession, user_id: uuid.UUID, integration: Integration, entity: Entity
):
    """Execute a single integration action."""
    provider = integration.provider
    config = integration.config

    if provider == "todoist":
        await create_todoist_task(config, entity)
    elif provider == "google_calendar":
        await create_calendar_event_for_entity(db, user_id, entity)
    elif provider == "notion":
        await create_notion_page(config, entity)
    elif provider == "telegram":
        await send_telegram_message(config, entity, heading="Echo")
    elif provider == "slack":
        await send_slack_message(config, entity, heading="Echo")
    else:
        logger.warning(f"[Integration] Unknown provider: {provider}")


async def create_calendar_event_for_entity(
    db: AsyncSession, user_id: uuid.UUID, entity: Entity
) -> dict | None:
    """Create a Google Calendar event from an event/task entity, if it has a usable date."""
    schedule = event_schedule_from_metadata(entity.metadata_)
    if schedule is None:
        logger.info(f"[Calendar] Skipping '{entity.name}' — no valid date extracted")
        return None
    day, start_time, duration_minutes = schedule
    return await create_event(
        db,
        user_id,
        summary=entity.name,
        date=day,
        time=start_time,
        location=(entity.metadata_ or {}).get("location"),
        description=entity.content,
        duration_minutes=duration_minutes,
    )
