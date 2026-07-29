"""Integration automation engine.

After entities are extracted, checks for active integrations
and triggers the appropriate action via HTTP webhook or MCP call.
"""

import logging
import uuid

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.entity import Entity
from app.models.integration import Integration

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
            await _execute_integration(integration, entity)
        except Exception as e:
            logger.error(
                f"[Integration] Failed to execute {integration.provider} "
                f"for entity '{entity.name}': {e}"
            )


async def _execute_integration(integration: Integration, entity: Entity):
    """Execute a single integration action."""
    provider = integration.provider
    config = integration.config

    if provider == "todoist":
        await _todoist_create_task(config, entity)
    elif provider == "google_calendar":
        await _google_calendar_create_event(config, entity)
    elif provider == "notion":
        await _notion_create_page(config, entity)
    elif provider == "telegram":
        await _telegram_send_message(config, entity)
    elif provider == "slack":
        await _slack_send_message(config, entity)
    else:
        logger.warning(f"[Integration] Unknown provider: {provider}")


async def _todoist_create_task(config: dict, entity: Entity):
    """Create a task in Todoist via REST API."""
    token = config.get("api_token")
    if not token:
        return

    due_date = entity.metadata_.get("due_date")
    priority_map = {"high": 4, "medium": 3, "low": 2}
    priority = priority_map.get(entity.metadata_.get("priority", ""), 1)

    body = {
        "content": entity.name,
        "description": entity.content or "",
        "priority": priority,
    }
    if due_date:
        body["due_string"] = due_date

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            "https://api.todoist.com/rest/v2/tasks",
            headers={"Authorization": f"Bearer {token}"},
            json=body,
        )
        if resp.status_code == 200:
            logger.info(f"[Todoist] Created task: {entity.name}")
        else:
            logger.warning(f"[Todoist] Failed ({resp.status_code}): {resp.text[:100]}")


async def _google_calendar_create_event(config: dict, entity: Entity):
    """Create event in Google Calendar via OAuth2 tokens."""
    access_token = config.get("access_token")
    refresh_token = config.get("refresh_token")

    if not access_token and not refresh_token:
        logger.warning("[Calendar] No tokens configured — skipping")
        return

    # Build event payload
    event_date = entity.metadata_.get("event_date")
    event_time = entity.metadata_.get("event_time")
    location = entity.metadata_.get("location")

    event_body: dict = {
        "summary": entity.name,
    }
    if entity.content:
        event_body["description"] = entity.content
    if location:
        event_body["location"] = location

    # Date handling: full day or timed event
    if event_date and event_time:
        event_body["start"] = {"dateTime": f"{event_date}T{event_time}:00", "timeZone": "Europe/Rome"}
        event_body["end"] = {"dateTime": f"{event_date}T{event_time}:00", "timeZone": "Europe/Rome"}
    elif event_date:
        event_body["start"] = {"date": event_date}
        event_body["end"] = {"date": event_date}
    else:
        # No date — skip, can't create event without date
        logger.info(f"[Calendar] Skipping event '{entity.name}' — no date extracted")
        return

    # Try with current access_token, refresh if 401
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            "https://www.googleapis.com/calendar/v3/calendars/primary/events",
            headers={"Authorization": f"Bearer {access_token}"},
            json=event_body,
        )

        if resp.status_code == 401 and refresh_token:
            # Token expired — refresh it
            new_token = await _google_refresh_token(refresh_token)
            if new_token:
                access_token = new_token
                resp = await client.post(
                    "https://www.googleapis.com/calendar/v3/calendars/primary/events",
                    headers={"Authorization": f"Bearer {access_token}"},
                    json=event_body,
                )

        if resp.status_code in (200, 201):
            logger.info(f"[Calendar] Created event: {entity.name}")
        else:
            logger.warning(f"[Calendar] Failed ({resp.status_code}): {resp.text[:200]}")


async def _google_refresh_token(refresh_token: str) -> str | None:
    """Refresh Google OAuth2 access token."""
    from app.core.config import settings

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            "https://oauth2.googleapis.com/token",
            data={
                "client_id": settings.google_client_id,
                "client_secret": settings.google_client_secret,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
        )
        if resp.status_code == 200:
            return resp.json().get("access_token")
        logger.error(f"[Calendar] Token refresh failed: {resp.text[:100]}")
        return None


async def _notion_create_page(config: dict, entity: Entity):
    """Create a page in Notion database."""
    token = config.get("api_key")
    database_id = config.get("database_id")
    if not token or not database_id:
        return

    body = {
        "parent": {"database_id": database_id},
        "properties": {
            "Name": {"title": [{"text": {"content": entity.name}}]},
        },
    }
    if entity.content:
        body["children"] = [
            {
                "object": "block",
                "type": "paragraph",
                "paragraph": {"rich_text": [{"text": {"content": entity.content}}]},
            }
        ]

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            "https://api.notion.com/v1/pages",
            headers={
                "Authorization": f"Bearer {token}",
                "Notion-Version": "2022-06-28",
                "Content-Type": "application/json",
            },
            json=body,
        )
        if resp.status_code == 200:
            logger.info(f"[Notion] Created page: {entity.name}")
        else:
            logger.warning(f"[Notion] Failed ({resp.status_code}): {resp.text[:100]}")


async def _telegram_send_message(config: dict, entity: Entity):
    """Send a message via Telegram bot."""
    bot_token = config.get("bot_token")
    chat_id = config.get("chat_id")
    if not bot_token or not chat_id:
        return

    text = f"🧠 *Echo*\n\n[{entity.entity_type.upper()}] *{entity.name}*"
    if entity.content:
        text += f"\n{entity.content}"

    async with httpx.AsyncClient() as client:
        await client.post(
            f"https://api.telegram.org/bot{bot_token}/sendMessage",
            json={"chat_id": chat_id, "text": text, "parse_mode": "Markdown"},
        )
        logger.info(f"[Telegram] Sent: {entity.name}")


async def _slack_send_message(config: dict, entity: Entity):
    """Send a message to Slack via webhook."""
    webhook_url = config.get("webhook_url")
    if not webhook_url:
        return

    text = f"🧠 *[{entity.entity_type.upper()}]* {entity.name}"
    if entity.content:
        text += f"\n> {entity.content}"

    async with httpx.AsyncClient() as client:
        await client.post(webhook_url, json={"text": text})
        logger.info(f"[Slack] Sent: {entity.name}")
