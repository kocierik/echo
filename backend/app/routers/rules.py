"""Rules API: CRUD for user-defined automation rules."""

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.rule import Rule

router = APIRouter(prefix="/rules", tags=["rules"])


# --- Schemas ---

class RuleOut(BaseModel):
    id: uuid.UUID
    name: str
    description: str | None
    enabled: bool
    conditions: dict
    actions: list
    trigger_count: int
    last_triggered_at: datetime | None
    created_at: datetime

    model_config = {"from_attributes": True}


class RuleCreate(BaseModel):
    name: str
    description: str | None = None
    conditions: dict
    actions: list
    enabled: bool = True


class RuleUpdate(BaseModel):
    name: str | None = None
    description: str | None = None
    conditions: dict | None = None
    actions: list | None = None
    enabled: bool | None = None


# --- Endpoints ---

@router.get("", response_model=list[RuleOut])
async def list_rules(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """List all user rules."""
    result = await db.execute(
        select(Rule).where(Rule.user_id == user_id).order_by(Rule.created_at.desc())
    )
    return result.scalars().all()


@router.post("", response_model=RuleOut, status_code=201)
async def create_rule(
    body: RuleCreate,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Create a new automation rule."""
    if not body.conditions:
        raise HTTPException(status_code=400, detail="At least one condition is required")
    if not body.actions:
        raise HTTPException(status_code=400, detail="At least one action is required")

    rule = Rule(
        user_id=user_id,
        name=body.name,
        description=body.description,
        enabled=body.enabled,
        conditions=body.conditions,
        actions=body.actions,
    )
    db.add(rule)
    await db.flush()
    await db.refresh(rule)
    return rule


@router.get("/{rule_id}", response_model=RuleOut)
async def get_rule(
    rule_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Get a single rule."""
    result = await db.execute(
        select(Rule).where(Rule.id == rule_id).where(Rule.user_id == user_id)
    )
    rule = result.scalar_one_or_none()
    if rule is None:
        raise HTTPException(status_code=404, detail="Rule not found")
    return rule


@router.patch("/{rule_id}", response_model=RuleOut)
async def update_rule(
    rule_id: uuid.UUID,
    body: RuleUpdate,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Update a rule."""
    result = await db.execute(
        select(Rule).where(Rule.id == rule_id).where(Rule.user_id == user_id)
    )
    rule = result.scalar_one_or_none()
    if rule is None:
        raise HTTPException(status_code=404, detail="Rule not found")

    if body.name is not None:
        rule.name = body.name
    if body.description is not None:
        rule.description = body.description
    if body.conditions is not None:
        rule.conditions = body.conditions
    if body.actions is not None:
        rule.actions = body.actions
    if body.enabled is not None:
        rule.enabled = body.enabled
    rule.updated_at = datetime.now(timezone.utc)
    return rule


@router.delete("/{rule_id}", status_code=204)
async def delete_rule(
    rule_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Delete a rule."""
    result = await db.execute(
        select(Rule).where(Rule.id == rule_id).where(Rule.user_id == user_id)
    )
    rule = result.scalar_one_or_none()
    if rule is None:
        raise HTTPException(status_code=404, detail="Rule not found")
    await db.delete(rule)


@router.get("/templates/examples")
async def get_rule_templates():
    """Get example rule templates for common use cases."""
    return [
        {
            "name": "High-priority tasks to Todoist",
            "description": "Send high-priority tasks automatically to Todoist",
            "conditions": {"entity_type": "task", "metadata.priority": "high"},
            "actions": [{"type": "todoist", "api_token": "YOUR_TOKEN"}],
        },
        {
            "name": "Events to Google Calendar",
            "description": "Auto-create calendar events when mentioned in conversation",
            "conditions": {"entity_type": "event"},
            "actions": [{"type": "google_calendar"}],
        },
        {
            "name": "Ideas to Notion",
            "description": "Save all ideas to a Notion database",
            "conditions": {"entity_type": "idea"},
            "actions": [{"type": "notion", "api_key": "YOUR_KEY", "database_id": "YOUR_DB"}],
        },
        {
            "name": "Notify on new person mentioned",
            "description": "Send Telegram notification when a new person is mentioned",
            "conditions": {"entity_type": "person"},
            "actions": [{"type": "telegram", "bot_token": "YOUR_BOT", "chat_id": "YOUR_CHAT"}],
        },
        {
            "name": "Webhook for all tasks",
            "description": "POST all extracted tasks to your custom endpoint",
            "conditions": {"entity_type": "task"},
            "actions": [{"type": "webhook", "url": "https://your-server.com/echo-webhook"}],
        },
        {
            "name": "Tag project-related entities",
            "description": "Tag any entity mentioning 'progetto' with a project tag",
            "conditions": {"name_contains": "progetto"},
            "actions": [{"type": "tag", "tag": "project"}],
        },
    ]
