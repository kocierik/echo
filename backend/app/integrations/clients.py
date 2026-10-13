"""HTTP clients for third-party integrations, shared by integrations and rules.

Each function takes the provider configuration (an Integration's `config` or a
rule action) and the entity, and returns True when the provider accepted it.
Missing credentials are a silent no-op (False).
"""

import logging

import httpx

from app.models.entity import Entity

logger = logging.getLogger(__name__)

TODOIST_TASKS_URL = "https://api.todoist.com/api/v1/tasks"  # REST v2 answers 410 Gone
NOTION_PAGES_URL = "https://api.notion.com/v1/pages"
NOTION_VERSION = "2022-06-28"
HTTP_TIMEOUT_S = 10

_TODOIST_PRIORITY = {"high": 4, "medium": 3, "low": 2}


def _ok(provider: str, response, label: str) -> bool:
    if response.status_code in (200, 201):
        logger.info(f"[{provider}] {label}")
        return True
    logger.warning(f"[{provider}] Failed ({response.status_code}): {response.text[:200]}")
    return False


def _entity_line(entity: Entity) -> str:
    return f"[{entity.entity_type.upper()}] {entity.name}"


async def create_todoist_task(config: dict, entity: Entity) -> bool:
    token = config.get("api_token")
    if not token:
        return False

    metadata = entity.metadata_ or {}
    body = {
        "content": entity.name,
        "description": entity.content or "",
        "priority": _TODOIST_PRIORITY.get(metadata.get("priority", ""), 1),
    }
    if config.get("project_id"):
        body["project_id"] = config["project_id"]
    if metadata.get("due_date"):
        body["due_string"] = metadata["due_date"]

    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT_S) as client:
        response = await client.post(
            TODOIST_TASKS_URL,
            headers={"Authorization": f"Bearer {token}"},
            json=body,
        )
    return _ok("Todoist", response, f"Created task: {entity.name}")


async def create_notion_page(config: dict, entity: Entity) -> bool:
    token = config.get("api_key")
    database_id = config.get("database_id")
    if not token or not database_id:
        return False

    body = {
        "parent": {"database_id": database_id},
        "properties": {"Name": {"title": [{"text": {"content": entity.name}}]}},
    }
    if entity.content:
        body["children"] = [{
            "object": "block",
            "type": "paragraph",
            "paragraph": {"rich_text": [{"text": {"content": entity.content}}]},
        }]

    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT_S) as client:
        response = await client.post(
            NOTION_PAGES_URL,
            headers={
                "Authorization": f"Bearer {token}",
                "Notion-Version": NOTION_VERSION,
                "Content-Type": "application/json",
            },
            json=body,
        )
    return _ok("Notion", response, f"Created page: {entity.name}")


async def send_telegram_message(config: dict, entity: Entity, heading: str = "Echo") -> bool:
    bot_token = config.get("bot_token")
    chat_id = config.get("chat_id")
    if not bot_token or not chat_id:
        return False

    # Plain text: user content may contain Markdown control characters
    text = f"{heading}\n\n{_entity_line(entity)}"
    if entity.content:
        text += f"\n{entity.content}"

    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT_S) as client:
        response = await client.post(
            f"https://api.telegram.org/bot{bot_token}/sendMessage",
            json={"chat_id": chat_id, "text": text},
        )
    return _ok("Telegram", response, f"Sent: {entity.name}")


async def send_slack_message(config: dict, entity: Entity, heading: str = "Echo") -> bool:
    webhook_url = config.get("webhook_url")
    if not webhook_url:
        return False

    text = f"*{heading}* {_entity_line(entity)}"
    if entity.content:
        text += f"\n> {entity.content}"

    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT_S) as client:
        response = await client.post(webhook_url, json={"text": text})
    return _ok("Slack", response, f"Sent: {entity.name}")
