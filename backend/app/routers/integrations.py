"""Integrations API: manage MCP integration store."""

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.integration import Integration

router = APIRouter(prefix="/integrations", tags=["integrations"])

# Load provider registry
_PROVIDERS_PATH = Path(__file__).parent.parent / "integrations" / "providers.json"


def _load_providers() -> list[dict]:
    if _PROVIDERS_PATH.exists():
        return json.loads(_PROVIDERS_PATH.read_text())
    return []


# --- Schemas ---

class IntegrationOut(BaseModel):
    id: uuid.UUID
    provider: str
    enabled: bool
    config: dict
    entity_types: list[str]
    created_at: datetime

    model_config = {"from_attributes": True}


class IntegrationCreate(BaseModel):
    provider: str
    config: dict = {}
    enabled: bool = True


class IntegrationUpdate(BaseModel):
    enabled: bool | None = None
    config: dict | None = None


# --- Endpoints ---

@router.get("/available")
async def list_available_providers():
    """List all available integration providers with metadata."""
    return _load_providers()


@router.get("", response_model=list[IntegrationOut])
async def list_integrations(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """List user's configured integrations."""
    result = await db.execute(
        select(Integration).where(Integration.user_id == user_id)
    )
    return result.scalars().all()


@router.post("", response_model=IntegrationOut, status_code=201)
async def create_integration(
    body: IntegrationCreate,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Enable an integration for the user."""
    # Find provider in registry
    providers = _load_providers()
    provider_meta = next((p for p in providers if p["id"] == body.provider), None)
    if provider_meta is None:
        raise HTTPException(status_code=400, detail=f"Unknown provider: {body.provider}")

    # Check if already exists
    existing = await db.execute(
        select(Integration)
        .where(Integration.user_id == user_id)
        .where(Integration.provider == body.provider)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(
            status_code=409, detail="Integration already exists. Use PATCH to update."
        )

    integration = Integration(
        user_id=user_id,
        provider=body.provider,
        enabled=body.enabled,
        config=body.config,
        entity_types=provider_meta.get("entity_types", []),
    )
    db.add(integration)
    return integration


@router.patch("/{integration_id}", response_model=IntegrationOut)
async def update_integration(
    integration_id: uuid.UUID,
    body: IntegrationUpdate,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Update integration config or toggle enabled."""
    result = await db.execute(
        select(Integration)
        .where(Integration.id == integration_id)
        .where(Integration.user_id == user_id)
    )
    integration = result.scalar_one_or_none()
    if integration is None:
        raise HTTPException(status_code=404, detail="Integration not found")

    if body.enabled is not None:
        integration.enabled = body.enabled
    if body.config is not None:
        integration.config = body.config
    integration.updated_at = datetime.now(timezone.utc)
    return integration


@router.delete("/{integration_id}", status_code=204)
async def delete_integration(
    integration_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Remove an integration."""
    result = await db.execute(
        select(Integration)
        .where(Integration.id == integration_id)
        .where(Integration.user_id == user_id)
    )
    integration = result.scalar_one_or_none()
    if integration is None:
        raise HTTPException(status_code=404, detail="Integration not found")
    await db.delete(integration)
