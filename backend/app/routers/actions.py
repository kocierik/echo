"""Actions API: Composio toolkits, confirmations, audit log and voice updates."""

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.composio_provider import get_action_provider
from app.actions.pending import (
    PendingActionExpired,
    PendingActionNotFound,
    PendingActionResolved,
    cancel_pending_action,
    confirm_pending_action,
)
from app.actions.provider import ActionProvider, ActionProviderError
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.action_log import ActionLog
from app.models.chat_session import ChatSession
from app.models.pending_action import PendingAction
from app.services.language import detect_language

router = APIRouter(prefix="/actions", tags=["actions"])

_MESSAGES = {
    "executed": {"en": "Done.", "it": "Fatto."},
    "failed": {
        "en": "That didn't work: {error}",
        "it": "Non è andata a buon fine: {error}",
    },
    "cancelled": {"en": "Cancelled.", "it": "Annullato."},
}


class ToolkitOut(BaseModel):
    slug: str
    name: str
    description: str
    connected: bool


class ActionLogOut(BaseModel):
    tool: str
    toolkit: str
    arguments_summary: str
    outcome: str
    error: str | None
    source: str
    created_at: datetime


def _get_provider() -> ActionProvider:
    try:
        return get_action_provider()
    except ActionProviderError as exc:
        raise HTTPException(status_code=503, detail="Composio is not configured") from exc


def _provider_failure(exc: ActionProviderError) -> HTTPException:
    return HTTPException(status_code=502, detail=(str(exc) or "Action provider error")[:200])


@router.get("/toolkits", response_model=list[ToolkitOut])
async def list_toolkits(
    query: str | None = None,
    user_id: uuid.UUID = Depends(get_current_user_id),
    provider: ActionProvider = Depends(_get_provider),
):
    try:
        toolkits = await provider.list_toolkits(str(user_id), query)
    except ActionProviderError as exc:
        raise _provider_failure(exc) from exc
    return [
        ToolkitOut(slug=t.slug, name=t.name, description=t.description, connected=t.connected)
        for t in toolkits
    ]


@router.post("/toolkits/{slug}/connect")
async def connect_toolkit(
    slug: str,
    user_id: uuid.UUID = Depends(get_current_user_id),
    provider: ActionProvider = Depends(_get_provider),
):
    try:
        url = await provider.connect_link(str(user_id), slug, None)
    except ActionProviderError as exc:
        raise _provider_failure(exc) from exc
    return {"url": url}


@router.delete("/toolkits/{slug}", status_code=204)
async def disconnect_toolkit(
    slug: str,
    user_id: uuid.UUID = Depends(get_current_user_id),
    provider: ActionProvider = Depends(_get_provider),
):
    try:
        await provider.disconnect(str(user_id), slug)
    except ActionProviderError as exc:
        raise _provider_failure(exc) from exc
    return Response(status_code=204)


async def _record_outcome(
    db: AsyncSession, user_id: uuid.UUID, action_id: uuid.UUID, status: str, error: str | None
) -> str:
    """Append the localized outcome message to the action's chat session."""
    action = await db.get(PendingAction, action_id)
    session = None
    if action is not None and action.session_id is not None:
        session = await db.get(ChatSession, action.session_id)
        if session is not None and session.user_id != user_id:
            session = None

    last_user = ""
    if session is not None:
        last_user = next(
            (m.get("content", "") for m in reversed(session.messages) if m.get("role") == "user"),
            "",
        )
    lang = detect_language(last_user) if last_user else "en"
    text = _MESSAGES[status][lang].format(error=error or "")

    if session is not None:
        messages = []
        for m in session.messages:
            pa = m.get("pending_action")
            if isinstance(pa, dict) and pa.get("id") == str(action_id):
                m = {**m, "pending_action": {**pa, "status": status}}
            messages.append(m)
        messages.append(
            {
                "role": "assistant",
                "content": text,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
        )
        session.messages = messages
    return text


@router.post("/pending/{action_id}/confirm")
async def confirm_action(
    action_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
    provider: ActionProvider = Depends(_get_provider),
):
    try:
        result = await confirm_pending_action(db, user_id, action_id, provider)
    except PendingActionNotFound as exc:
        raise HTTPException(status_code=404, detail="Pending action not found") from exc
    except PendingActionResolved as exc:
        raise HTTPException(status_code=409, detail="Action already resolved") from exc
    except PendingActionExpired as exc:
        await db.commit()  # persist the "expired" status; get_db would roll back
        raise HTTPException(status_code=410, detail="Action expired") from exc

    status = "executed" if result.ok else "failed"
    message = await _record_outcome(db, user_id, action_id, status, result.error)
    return {"status": status, "message": message}


@router.post("/pending/{action_id}/cancel")
async def cancel_action(
    action_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        await cancel_pending_action(db, user_id, action_id)
    except PendingActionNotFound as exc:
        raise HTTPException(status_code=404, detail="Pending action not found") from exc
    except PendingActionResolved as exc:
        raise HTTPException(status_code=409, detail="Action already resolved") from exc
    await _record_outcome(db, user_id, action_id, "cancelled", None)
    return {"status": "cancelled"}


@router.get("/log", response_model=list[ActionLogOut])
async def action_log(
    limit: int = Query(50, ge=1, le=200),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(ActionLog)
        .where(ActionLog.user_id == user_id)
        .order_by(ActionLog.created_at.desc())
        .limit(limit)
    )
    return [
        ActionLogOut(
            tool=row.tool,
            toolkit=row.toolkit,
            arguments_summary=row.arguments_summary,
            outcome=row.outcome,
            error=row.error,
            source=row.source,
            created_at=row.created_at,
        )
        for row in result.scalars().all()
    ]


def _parse_ts(value) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


@router.get("/voice-updates")
async def voice_updates(
    since: datetime | None = None,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    if since is not None and since.tzinfo is None:
        since = since.replace(tzinfo=timezone.utc)
    result = await db.execute(
        select(ChatSession)
        .where(ChatSession.user_id == user_id, ChatSession.kind == "voice")
        .order_by(ChatSession.updated_at.desc())
        .limit(1)
    )
    session = result.scalars().all()
    session = session[0] if session else None

    messages = []
    if session is not None:
        for m in session.messages:
            if m.get("role") != "assistant":
                continue
            ts = _parse_ts(m.get("timestamp"))
            if ts is None or (since is not None and ts <= since):
                continue
            messages.append(
                {
                    "session_id": str(session.id),
                    "role": "assistant",
                    "content": m.get("content", ""),
                    "timestamp": m["timestamp"],
                    "pending_action": m.get("pending_action"),
                }
            )
    return {"messages": messages, "now": datetime.now(timezone.utc).isoformat()}
