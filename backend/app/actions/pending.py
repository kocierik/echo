import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.audit import log_action
from app.actions.provider import ActionProvider, ActionProviderError, ToolResult
from app.models.pending_action import PendingAction

PENDING_TTL = timedelta(minutes=30)


class PendingActionNotFound(Exception):  # noqa: N818
    """No such pending action for this user (HTTP 404)."""


class PendingActionResolved(Exception):  # noqa: N818
    """Action already executed, failed, cancelled or expired (HTTP 409)."""


class PendingActionExpired(Exception):  # noqa: N818
    """Action's confirmation window has passed (HTTP 410)."""


async def create_pending_action(
    db: AsyncSession,
    user_id: uuid.UUID,
    session_id: uuid.UUID | None,
    source: str,
    tool: str,
    arguments: dict,
    summary: str,
) -> PendingAction:
    now = datetime.now(timezone.utc)
    action = PendingAction(
        user_id=user_id,
        session_id=session_id,
        source=source,
        tool=tool,
        arguments=arguments,
        summary=summary,
        status="pending",
        created_at=now,
        expires_at=now + PENDING_TTL,
    )
    db.add(action)
    await db.flush()
    return action


async def _load_locked(db: AsyncSession, user_id: uuid.UUID, action_id: uuid.UUID):
    result = await db.execute(
        select(PendingAction)
        .where(PendingAction.id == action_id, PendingAction.user_id == user_id)
        .with_for_update()
    )
    action = result.scalar_one_or_none()
    if action is None or action.user_id != user_id:
        raise PendingActionNotFound(str(action_id))
    return action


async def confirm_pending_action(
    db: AsyncSession,
    user_id: uuid.UUID,
    action_id: uuid.UUID,
    provider: ActionProvider,
    now: datetime | None = None,
) -> ToolResult:
    now = now or datetime.now(timezone.utc)
    action = await _load_locked(db, user_id, action_id)
    if action.status != "pending":
        raise PendingActionResolved(action.status)
    if now >= action.expires_at:
        action.status = "expired"
        action.resolved_at = now
        await db.flush()
        raise PendingActionExpired(str(action_id))

    try:
        result = await provider.execute(str(user_id), action.tool, action.arguments)
    except ActionProviderError as exc:
        result = ToolResult(ok=False, error=str(exc) or type(exc).__name__)

    await log_action(db, user_id, action.source, action.tool, action.arguments, result)
    action.status = "executed" if result.ok else "failed"
    action.resolved_at = now
    await db.flush()
    return result


async def cancel_pending_action(
    db: AsyncSession, user_id: uuid.UUID, action_id: uuid.UUID
) -> PendingAction:
    action = await _load_locked(db, user_id, action_id)
    if action.status != "pending":
        raise PendingActionResolved(action.status)
    action.status = "cancelled"
    action.resolved_at = datetime.now(timezone.utc)
    await db.flush()
    return action
