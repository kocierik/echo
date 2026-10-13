"""Rules Engine — evaluate user-defined rules against extracted entities.

Supports conditions on:
- entity_type: exact match (task, event, person, idea, note)
- name_contains: substring match on entity name (case-insensitive)
- content_contains: substring match on entity content
- metadata.*: dot-notation access to metadata fields (e.g. metadata.priority = "high")
- speaker: who spoke in the source Segment (self/other/unknown; "tu"/"altri" also accepted)

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
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.clients import (
    create_notion_page,
    create_todoist_task,
    send_slack_message,
    send_telegram_message,
)
from app.integrations.engine import create_calendar_event_for_entity
from app.models.entity import Entity
from app.models.rule import Rule
from app.models.segment import Segment
from app.models.transcription import Transcription

logger = logging.getLogger(__name__)

RULE_HEADING = "Rule triggered"


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

    # The speaker lives on the source Segment: look it up only if a rule needs it
    speaker = None
    if any("speaker" in (rule.conditions or {}) for rule in rules):
        speaker = await _entity_speaker(db, entity)

    triggered = 0
    for rule in rules:
        if _matches_conditions(rule.conditions, entity, speaker=speaker):
            logger.info(f"[Rules] Rule '{rule.name}' triggered by entity '{entity.name}'")
            await _execute_actions(rule.actions, entity, db, user_id)

            # Update stats
            rule.trigger_count += 1
            rule.last_triggered_at = datetime.now(timezone.utc)
            triggered += 1

    return triggered


_SPEAKER_ALIASES = {
    "self": "self", "tu": "self", "you": "self", "me": "self", "io": "self",
    "other": "other", "others": "other", "altri": "other", "altro": "other",
    "unknown": "unknown",
}


def normalize_speaker(value) -> str | None:
    """Canonical speaker label (self/other/unknown) for rule values and data."""
    if value is None:
        return None
    return _SPEAKER_ALIASES.get(str(value).strip().strip("[]").lower())


async def _entity_speaker(db: AsyncSession, entity: Entity) -> str | None:
    """Speaker of the Segment the entity was extracted from (corrected label first)."""
    if entity.source_transcription_id is None:
        return None
    result = await db.execute(
        select(Transcription.speaker_label, Segment.speaker)
        .join(Segment, Segment.id == Transcription.segment_id)
        .where(Transcription.id == entity.source_transcription_id)
    )
    row = result.first()
    if row is None:
        return None
    speaker_label, segment_speaker = row
    return normalize_speaker(speaker_label or segment_speaker)


def _matches_conditions(
    conditions: dict, entity: Entity, speaker: str | None = None
) -> bool:
    """Check if ALL conditions match the entity (AND logic)."""
    if not conditions:
        return True  # No conditions = always match

    for key, expected in conditions.items():
        actual = _get_entity_value(key, entity)

        if key == "speaker":
            if speaker is None or normalize_speaker(expected) != speaker:
                return False
        elif key.endswith("_contains"):
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
                await create_todoist_task(action, entity)
            elif action_type == "notion":
                await create_notion_page(action, entity)
            elif action_type == "telegram":
                await send_telegram_message(action, entity, heading=RULE_HEADING)
            elif action_type == "slack":
                await send_slack_message(action, entity, heading=RULE_HEADING)
            elif action_type == "google_calendar":
                await create_calendar_event_for_entity(db, user_id, entity)
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
