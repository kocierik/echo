"""Actions API: Composio toolkits, confirmations, audit log and voice updates."""

import json
import logging
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.availability import APP_NAMES
from app.actions.composio_provider import get_action_provider
from app.actions.pending import (
    PendingActionExpired,
    PendingActionNotFound,
    PendingActionResolved,
    cancel_pending_action,
    confirm_pending_action,
)
from app.actions.policy import toolkit_of
from app.actions.provider import ActionProvider, ActionProviderError
from app.actions.voice import WORKING_KEY
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.action_log import ActionLog
from app.models.chat_session import ChatSession
from app.models.pending_action import PendingAction
from app.models.photo import Photo
from app.models.routine_run import RoutineRun
from app.services.chat_history import save_session_history
from app.services.language import detect_language

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/actions", tags=["actions"])

# Raw provider error text shown in chat and confirm responses.
_ERROR_MAX = 200

_MESSAGES = {
    "executed": {"en": "Done.", "it": "Fatto."},
    "failed": {
        "en": "That didn't work: {error}",
        "it": "Non è andata a buon fine: {error}",
    },
    "cancelled": {"en": "Cancelled.", "it": "Annullato."},
    "unknown": {
        "en": "I couldn't confirm whether it went through — check {app} before trying again.",
        "it": (
            "Non sono riuscito a verificare se è andata a buon fine: "
            "controlla {app} prima di riprovare."
        ),
    },
}


class ToolkitOut(BaseModel):
    slug: str
    name: str
    description: str
    connected: bool


class PendingActionOut(BaseModel):
    id: uuid.UUID
    summary: str
    tool: str
    app: str
    source: str
    session_id: uuid.UUID | None
    created_at: datetime
    expires_at: datetime


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


def _get_redis(request: Request):
    return request.app.state.redis


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


async def _append_to_context(redis_client, session_id: uuid.UUID, text: str) -> None:
    """Add the outcome to the session's Redis context (if still alive) for the next turn."""
    if redis_client is None:
        return
    try:
        raw = await redis_client.get(f"session:{session_id}")
        if raw is None:
            return
        history = json.loads(raw)
        history.append({"role": "assistant", "content": text, "actions": True})
        await save_session_history(redis_client, str(session_id), history)
    except Exception:
        logger.warning("Could not add the action outcome to the chat context", exc_info=True)


async def _record_outcome(
    db: AsyncSession,
    user_id: uuid.UUID,
    action_id: uuid.UUID,
    status: str,
    error: str | None,
    redis_client=None,
) -> str:
    """Append the localized outcome message to the action's chat session.

    The message carries "outcome": True (so /voice-updates does not notify it) and, for
    a chat session whose Redis context is still alive, is added to that context too.
    """
    action = await db.get(PendingAction, action_id)
    session = None
    if action is not None and action.session_id is not None:
        # Locked: voice answers and photos rewrite the same message list
        session = await db.get(ChatSession, action.session_id, with_for_update=True)
        if session is not None and session.user_id != user_id:
            session = None

    last_user = ""
    if session is not None:
        last_user = next(
            (m.get("content", "") for m in reversed(session.messages) if m.get("role") == "user"),
            "",
        )
    lang = detect_language(last_user) if last_user else "en"
    toolkit = toolkit_of(action.tool) if action is not None and action.tool else ""
    app = APP_NAMES.get(toolkit, toolkit.title() or "the app")
    text = _MESSAGES[status][lang].format(error=(error or "")[:_ERROR_MAX], app=app)

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
                "outcome": True,
            }
        )
        session.messages = messages
        if session.kind == "chat":
            await _append_to_context(redis_client, session.id, text)
    return text


@router.get("/pending", response_model=list[PendingActionOut])
async def list_pending_actions(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Actions waiting for a Confirm (from chat or voice) that have not expired, newest first."""
    rows = (
        await db.execute(
            select(PendingAction)
            .where(PendingAction.user_id == user_id)
            .where(PendingAction.status == "pending")
            .where(PendingAction.expires_at > datetime.now(timezone.utc))
            .order_by(PendingAction.created_at.desc())
            .limit(20)
        )
    ).scalars().all()
    return [
        PendingActionOut(
            id=row.id,
            summary=row.summary,
            tool=row.tool,
            app=APP_NAMES.get(toolkit_of(row.tool), toolkit_of(row.tool).title()),
            source=row.source,
            session_id=row.session_id,
            created_at=row.created_at,
            expires_at=row.expires_at,
        )
        for row in rows
    ]


@router.post("/pending/{action_id}/confirm")
async def confirm_action(
    action_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
    redis_client=Depends(_get_redis),
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

    if result.ok:
        status = "executed"
    else:
        status = "unknown" if result.unknown else "failed"
    message = await _record_outcome(
        db, user_id, action_id, status, result.error, redis_client
    )
    return {"status": status, "message": message}


@router.post("/pending/{action_id}/cancel")
async def cancel_action(
    action_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
    redis_client=Depends(_get_redis),
):
    try:
        await cancel_pending_action(db, user_id, action_id)
    except PendingActionNotFound as exc:
        raise HTTPException(status_code=404, detail="Pending action not found") from exc
    except PendingActionResolved as exc:
        raise HTTPException(status_code=409, detail="Action already resolved") from exc
    await _record_outcome(db, user_id, action_id, "cancelled", None, redis_client)
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
            # Confirm/cancel outcomes answer a tap in the app, and so does a photo taken
            # with the app's button: no notification
            if m.get("role") != "assistant" or m.get("outcome") or m.get("notify") is False:
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
                    "photo_id": m.get("photo_id"),
                }
            )
    # Routine runs with something to say, or that failed; with no `since` the phone's
    # first check only sets its clock, as for messages
    routine_runs = []
    if since is not None:
        runs = await db.scalars(
            select(RoutineRun)
            .where(
                RoutineRun.user_id == user_id,
                RoutineRun.status.in_(("reported", "failed")),
                RoutineRun.ran_at > since,
            )
            .order_by(RoutineRun.ran_at)
        )
        routine_runs = [
            {
                "id": str(run.id),
                "routine_id": str(run.routine_id),
                "status": run.status,
                "text": run.text,
                "ran_at": run.ran_at.isoformat(),
            }
            for run in runs
        ]
    return {
        "messages": messages,
        "routine_runs": routine_runs,
        "now": datetime.now(timezone.utc).isoformat(),
    }


# A photo still waiting for the wearable or the vision model this long is shown as working
PHOTO_WORKING_WINDOW = timedelta(minutes=10)


@router.get("/voice-working")
async def voice_working(
    request: Request,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Voice requests Echo is answering right now, and photos on their way: the app shows
    "Echo is working on it" until the answer arrives."""
    items = []
    raw = await request.app.state.redis.hgetall(WORKING_KEY.format(user_id=user_id))
    for key, value in (raw or {}).items():
        try:
            entry = json.loads(value)
            items.append(
                {
                    "key": f"request:{key.decode() if isinstance(key, bytes) else key}",
                    "kind": "request",
                    "text": entry["command"],
                    "since": entry["since"],
                }
            )
        except (ValueError, KeyError, TypeError):
            continue
    since = datetime.now(timezone.utc) - PHOTO_WORKING_WINDOW
    photos = await db.execute(
        select(Photo)
        .where(Photo.user_id == user_id, Photo.status.in_(("requested", "received")))
        .where(Photo.created_at >= since)
        .order_by(Photo.created_at)
    )
    for photo in photos.scalars():
        items.append(
            {
                "key": f"photo:{photo.id}",
                "kind": "photo",
                "text": photo.question or "",
                "since": photo.created_at.isoformat(),
                "session_id": str(photo.chat_session_id) if photo.chat_session_id else None,
            }
        )
    return {"items": sorted(items, key=lambda item: item["since"])}
