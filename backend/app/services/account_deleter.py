"""Deleting an account: every row with its user id (and, through the cascades, what hangs
off them), its audio on disk, its keys in Redis, and best effort its links elsewhere
(WhatsApp, the apps connected through Composio).

The daily backups still hold it until they are rotated (scripts/backup.sh, 14 days).
"""

import logging
import shutil
import uuid
from pathlib import Path

from sqlalchemy import delete, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.api_key import ApiKey
from app.models.user import User

logger = logging.getLogger(__name__)


async def _unlink_elsewhere(user_id: uuid.UUID) -> None:
    """WhatsApp and the connected apps; a failure is logged, never stops the deletion."""
    from app.services import whatsapp_bridge

    bridge = whatsapp_bridge.get_bridge()
    if bridge is not None:
        try:
            await bridge.unlink(user_id)
        except Exception:
            logger.warning("Account %s: WhatsApp not unlinked", user_id, exc_info=True)
    try:
        from app.actions.composio_provider import get_action_provider

        provider = get_action_provider()
        for toolkit in await provider.connected_toolkits(str(user_id)):
            await provider.disconnect(str(user_id), toolkit)
    except Exception:
        logger.warning("Account %s: connected apps not disconnected", user_id, exc_info=True)


async def delete_account(
    db: AsyncSession, redis_client, user_id: uuid.UUID, *, audio_root: Path
) -> list[str]:
    """Deletes the account; the hashes of the keys it had (to remember them as revoked)."""
    await _unlink_elsewhere(user_id)

    key_hashes = list(
        (await db.execute(select(ApiKey.key_hash).where(ApiKey.user_id == user_id))).scalars()
    )
    # Every table with a user id, so a table added later is not forgotten
    tables = (
        await db.execute(
            text(
                "SELECT table_name FROM information_schema.columns "
                "WHERE column_name = 'user_id' AND table_schema = 'public'"
            )
        )
    ).scalars().all()
    for table in tables:
        await db.execute(text(f'DELETE FROM "{table}" WHERE user_id = :u'), {"u": user_id})
    await db.execute(delete(User).where(User.id == user_id))
    await db.commit()

    # After the commit: a failed delete keeps the audio its rows point at
    shutil.rmtree(audio_root / str(user_id), ignore_errors=True)
    if redis_client is not None:
        try:
            found = [key async for key in redis_client.scan_iter(match=f"*{user_id}*")]
            if found:
                await redis_client.delete(*found)
        except Exception:
            logger.warning("Account %s: Redis keys not cleared", user_id, exc_info=True)
    logger.info("Account %s deleted", user_id)
    return key_hashes
