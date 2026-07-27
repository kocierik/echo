"""Rules Engine — evaluate user-defined rules against extracted entities.

Supports conditions on:
- entity_type: exact match (task, event, person, idea, note)
- name_contains: substring match on entity name (case-insensitive)
- content_contains: substring match on entity content
- metadata.*: dot-notation access to metadata fields (e.g. metadata.priority = "high")
- speaker: match speaker tag (self, other)

Actions:
- webhook: POST JSON to a URL
- todoist: create task in Todoist
- notion: create page in Notion
- telegram: send message via bot
- slack: post to webhook
- google_calendar: create event
- tag: add a tag to the entity metadata
- notify: send push notification (future)
"""

import logging
import uuid
from datetime import datetime, timezone

import httpx
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.entity import Entity
from app.models.rule import Rule

logger = logging.getLogger(__name__)


async def evaluate_rules(db: AsyncSession, user_id: uuid.UUID, entity: Entity) -> int:
    """Evaluate all active rules for this user against the entity.

    Returns the number of rules triggered.
    """
    result = await db.execute(
        select(Rule)
        .where(Rule.user_id == user_id)
        .where(Rule.enabled.is_(True))
    )
    rules = result.scalars().all()

    triggered = 0
    for rule in rules:
        if _matches_conditions(rule.conditions, entity):
            logger.info(f"[Rules] Rule '{rule.name}' triggered by entity '{entity.name}'")
            await _execute_actions(rule.actions, entity, db, user_id)

            # Update stats
            rule.trigger_count += 1
            rule.last_triggered_at = datetime.now(timezone.utc)
            triggered += 1

    return triggered


def _matches_conditions(conditions: dict, entity: Entity) -> bool:
    """Check if ALL conditions match the entity (AND logic)."""
    if not conditions:
        return True  # No conditions = always match

    for key, expected in conditions.items():
        actual = _get_entity_value(key, entity)

        if key.endswith("_contains"):
            # Substring match
            field = key.replace("_contains", "")
            actual = _get_entity_value(field, entity)
            if actual is None or str(expected).lower() not in str(actual).lower():
                return False
        elif key == "entity_type":
            if entity.entity_type != expected:
                return False
        elif key.startswith("metadata."):
            meta_key = key.replace("metadata.", "")
            meta_val = entity.metadata_.get(meta_key) if entity.metadata_ else None
            if str(meta_val).lower() != str(expected).lower():
                return False
        else:
            if str(actual).lower() != str(expected).lower():
                return False

    return True


def _get_entity_value(key: str, entity: Entity):
    """Get a value from entity by key name."""
    if key == "entity_type":
        return entity.entity_type
    elif key == "name":
        return entity.name
    elif key == "content":
        return entity.content
    elif key == "speaker":
        # Speaker is in the transcription text prefix [Tu] or [Altri]
        if entity.content and entity.content.startswith("["):
            return entity.content.split("]")[0].strip("[").lower()
        return None
    elif key.startswith("metadata."):
        meta_key = key.replace("metadata.", "")
        return entity.metadata_.get(meta_key) if entity.metadata_ else None
    return None


async def _execute_actions(actions: list, entity: Entity, db: AsyncSession, user_id: uuid.UUID):
    """Execute all actions for a triggered rule."""
    for action in actions:
        action_type = action.get("type", "")
        try:
            if action_type == "webhook":
                await _action_webhook(action, entity)
            elif action_type == "todoist":
                await _action_todoist(action, entity)
            elif action_type == "notion":
                await _action_notion(action, entity)
            elif action_type == "telegram":
                await _action_telegram(action, entity)
            elif action_type == "slack":
                await _action_slack(action, entity)
            elif action_type == "google_calendar":
                from app.services.calendar_service import create_event
                date = entity.metadata_.get("event_date") or entity.metadata_.get("due_date")
                time = entity.metadata_.get("event_time")
                if date:
                    await create_event(db, user_id, summary=entity.name, date=date, time=time)
            elif action_type == "tag":
                # Add tag to entity metadata
                tag = action.get("tag", "flagged")
                if entity.metadata_ is None:
                    entity.metadata_ = {}
                tags = entity.metadata_.get("tags", [])
                if tag not in tags:
                    tags.append(tag)
                    entity.metadata_["tags"] = tags
            else:
                logger.warning(f"[Rules] Unknown action type: {action_type}")
        except Exception as e:
            logger.error(f"[Rules] Action '{action_type}' failed: {e}")


async def _action_webhook(action: dict, entity: Entity):
    """POST entity data to a webhook URL."""
    url = action.get("url")
    if not url:
        return

    payload = {
        "event": "rule_triggered",
        "entity": {
            "id": str(entity.id) if entity.id else None,
            "type": entity.entity_type,
            "name": entity.name,
            "content": entity.content,
            "metadata": entity.metadata_,
        },
        "triggered_at": datetime.now(timezone.utc).isoformat(),
    }

    # Add custom fields from action config
    if action.get("headers"):
        headers = action["headers"]
    else:
        headers = {"Content-Type": "application/json"}

    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(url, json=payload, headers=headers)
        logger.info(f"[Rules/Webhook] POST {url} → {resp.status_code}")


async def _action_todoist(action: dict, entity: Entity):
    """Create Todoist task from rule action."""
    token = action.get("api_token")
    if not token:
        return

    body = {
        "content": entity.name,
        "description": entity.content or "",
    }
    if action.get("project_id"):
        body["project_id"] = action["project_id"]
    if entity.metadata_.get("due_date"):
        body["due_string"] = entity.metadata_["due_date"]
    if entity.metadata_.get("priority"):
        priority_map = {"high": 4, "medium": 3, "low": 2}
        body["priority"] = priority_map.get(entity.metadata_["priority"], 1)

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            "https://api.todoist.com/rest/v2/tasks",
            headers={"Authorization": f"Bearer {token}"},
            json=body,
        )
        logger.info(f"[Rules/Todoist] Created task → {resp.status_code}")


async def _action_notion(action: dict, entity: Entity):
    """Create Notion page from rule action."""
    token = action.get("api_key")
    database_id = action.get("database_id")
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
            {"object": "block", "type": "paragraph",
             "paragraph": {"rich_text": [{"text": {"content": entity.content}}]}}
        ]

    async with httpx.AsyncClient() as client:
        await client.post(
            "https://api.notion.com/v1/pages",
            headers={"Authorization": f"Bearer {token}", "Notion-Version": "2022-06-28"},
            json=body,
        )
        logger.info(f"[Rules/Notion] Created page: {entity.name}")


async def _action_telegram(action: dict, entity: Entity):
    """Send Telegram message from rule action."""
    bot_token = action.get("bot_token")
    chat_id = action.get("chat_id")
    if not bot_token or not chat_id:
        return

    text = f"🤖 Rule triggered\n\n[{entity.entity_type.upper()}] {entity.name}"
    if entity.content:
        text += f"\n{entity.content}"

    async with httpx.AsyncClient() as client:
        await client.post(
            f"https://api.telegram.org/bot{bot_token}/sendMessage",
            json={"chat_id": chat_id, "text": text, "parse_mode": "Markdown"},
        )


async def _action_slack(action: dict, entity: Entity):
    """Post to Slack webhook from rule action."""
    webhook_url = action.get("webhook_url")
    if not webhook_url:
        return

    text = f"🤖 *Rule triggered*\n[{entity.entity_type.upper()}] *{entity.name}*"
    if entity.content:
        text += f"\n> {entity.content}"

    async with httpx.AsyncClient() as client:
        await client.post(webhook_url, json={"text": text})
