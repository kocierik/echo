import hashlib
from uuid import UUID

from fastapi import Depends, HTTPException, Security, status
from fastapi.security import APIKeyHeader
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.models.api_key import ApiKey

api_key_header = APIKeyHeader(name="X-API-Key")


def hash_api_key(key: str) -> str:
    """Hash an API key with SHA-256."""
    return hashlib.sha256(key.encode()).hexdigest()


async def get_current_user_id(
    api_key: str = Security(api_key_header),
    db: AsyncSession = Depends(get_db),
) -> UUID:
    """Validate API key and return the associated user_id."""
    key_hash = hash_api_key(api_key)
    result = await db.execute(select(ApiKey).where(ApiKey.key_hash == key_hash))
    api_key_record = result.scalar_one_or_none()

    if api_key_record is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key",
        )

    # Update last_used_at
    from datetime import datetime, timezone

    api_key_record.last_used_at = datetime.now(timezone.utc)

    return api_key_record.user_id
