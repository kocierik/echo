import hashlib
import hmac
import logging
from datetime import datetime, timezone
from uuid import UUID

from fastapi import Depends, HTTPException, Request, Security, status
from fastapi.security import APIKeyHeader
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_db
from app.models.api_key import ApiKey
from app.services.usage import usage_owner

logger = logging.getLogger(__name__)

api_key_header = APIKeyHeader(name="X-API-Key")

# Failed key attempts per client: after the limit, every attempt (even with the right
# key, so the answer reveals nothing) gets 429 until the window ends.
AUTH_FAILURE_LIMIT = 10
AUTH_FAILURE_WINDOW_SECONDS = 15 * 60

# A key deleted (signed out, revoked) is remembered this long: the phone that still
# holds it may fire a burst of requests, and those must not lock out its address
REVOKED_KEY_SECONDS = 24 * 3600


# The README's example key, known to everyone: never accepted, even if a server still has it
EXAMPLE_KEY_HASH = hashlib.sha256(b"my-secret-key").hexdigest()


def hash_api_key(key: str) -> str:
    """Hash an API key with SHA-256."""
    return hashlib.sha256(key.encode()).hexdigest()


def client_address(request: Request) -> str:
    """The real client behind Cloudflare Tunnel (CF-Connecting-IP), else the peer address.

    The header is trusted: only the tunnel should reach the API port.
    """
    forwarded = request.headers.get("CF-Connecting-IP")
    if forwarded:
        return forwarded.strip()
    return request.client.host if request.client else "unknown"


def client_failure_key(request: Request) -> str:
    return "auth_fail:" + client_address(request)


def mcp_failure_key(request: Request) -> str:
    """Failed connected-app keys from a client, apart from the REST API's: a revoked app
    left in an assistant's config keeps retrying, and must never lock the phone out."""
    return "mcp_auth_fail:" + client_address(request)


def login_failure_key(request: Request) -> str:
    """Failed sign-ins from a client, apart from failed keys (a revoked phone's)."""
    return "login_fail:" + client_address(request)


def email_failure_key(email: str) -> str:
    """Failed sign-ins for one account, whatever the client (the email is not stored)."""
    return "auth_fail_email:" + hashlib.sha256(email.encode()).hexdigest()[:16]


async def blocked_for(redis, key: str) -> int | None:
    """Seconds left when `key` has reached the failure limit, else None."""
    try:
        failures = await redis.get(key)
        if failures is None or int(failures) < AUTH_FAILURE_LIMIT:
            return None
        ttl = await redis.ttl(key)
    except Exception as exc:  # Redis down: never lock everyone out
        logger.warning("auth failure limit unavailable: %s", exc)
        return None
    return ttl if ttl > 0 else AUTH_FAILURE_WINDOW_SECONDS


async def reserve_attempt(
    redis,
    key: str,
    *,
    limit: int = AUTH_FAILURE_LIMIT,
    window: int = AUTH_FAILURE_WINDOW_SECONDS,
) -> int | None:
    """Counts an attempt before it is checked, so a burst of simultaneous attempts
    cannot all slip under the limit: seconds left when it is over, else None."""
    try:
        count = await redis.incr(key)
        if count == 1:
            await redis.expire(key, window)
        if count <= limit:
            return None
        ttl = await redis.ttl(key)
    except Exception as exc:  # Redis down: never lock everyone out
        logger.warning("auth failure limit unavailable: %s", exc)
        return None
    return ttl if ttl > 0 else window


async def release_attempt(redis, key: str) -> None:
    """Gives back an attempt that succeeded."""
    try:
        await redis.decr(key)
    except Exception as exc:
        logger.warning("auth failure limit unavailable: %s", exc)


def _revoked_key(key_hash: str) -> str:
    return "revoked_key:" + key_hash


async def remember_revoked(redis, key_hash: str) -> None:
    """A deleted key: its phone's later 401s do not count as failed attempts."""
    try:
        await redis.set(_revoked_key(key_hash), "1", ex=REVOKED_KEY_SECONDS)
    except Exception as exc:
        logger.warning("revoked key not remembered: %s", exc)


async def _was_revoked(redis, key_hash: str) -> bool:
    try:
        return await redis.get(_revoked_key(key_hash)) is not None
    except Exception:
        return False


async def _check_not_blocked(redis, key: str) -> None:
    seconds = await blocked_for(redis, key)
    if seconds is None:
        return
    raise HTTPException(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        detail="Too many invalid API key attempts. Try again later.",
        headers={"Retry-After": str(seconds)},
    )


async def record_failure(redis, key: str) -> None:
    try:
        if await redis.incr(key) == 1:
            await redis.expire(key, AUTH_FAILURE_WINDOW_SECONDS)
    except Exception as exc:
        logger.warning("auth failure limit unavailable: %s", exc)


async def get_current_api_key(
    request: Request,
    api_key: str = Security(api_key_header),
    db: AsyncSession = Depends(get_db),
) -> ApiKey:
    """The key the request was made with (401 when unknown, 429 after too many)."""
    return await _key_for(request, api_key, db, {"full"})


async def get_health_writer(
    request: Request,
    api_key: str = Security(api_key_header),
    db: AsyncSession = Depends(get_db),
) -> ApiKey:
    """A key that may send the day's health data: the phone's, or the one made for Apple's
    Shortcuts (scope "health"), which can do nothing else."""
    return await _key_for(request, api_key, db, {"full", "health"})


async def _key_for(request: Request, api_key: str, db: AsyncSession, scopes: set[str]) -> ApiKey:
    redis = getattr(request.app.state, "redis", None)
    failure_key = client_failure_key(request)
    if redis is not None:
        await _check_not_blocked(redis, failure_key)

    key_hash = hash_api_key(api_key)
    api_key_record = None
    if key_hash != EXAMPLE_KEY_HASH:
        result = await db.execute(select(ApiKey).where(ApiKey.key_hash == key_hash))
        api_key_record = result.scalar_one_or_none()

    if api_key_record is None:
        if redis is not None and not await _was_revoked(redis, key_hash):
            await record_failure(redis, failure_key)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key",
        )

    scope = getattr(api_key_record, "scope", "full")
    if scope not in scopes:
        # A real key, used in the wrong place: a connected app's, or the Shortcuts' one
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This key only sends health data."
            if scope == "health"
            else "This key is for connected apps only.",
        )

    api_key_record.last_used_at = datetime.now(timezone.utc)
    # The model calls of this request are counted for the key's user (services/usage.py)
    usage_owner.set(api_key_record.user_id)
    # Rate limits are per account, not per key (core/rate_limit.py)
    request.state.rate_limit_owner = str(api_key_record.user_id)

    return api_key_record


async def require_operator(request: Request) -> None:
    """The server's operator (`X-Admin-Token`, ADMIN_TOKEN): what concerns every user,
    such as the failed jobs. Without ADMIN_TOKEN set, these endpoints do not exist."""
    expected = settings.admin_token
    if not expected:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not Found")
    given = request.headers.get("X-Admin-Token", "")
    if not hmac.compare_digest(given.encode(), expected.encode()):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Operator only")


async def authenticate_connected_app(request: Request, db: AsyncSession) -> ApiKey:
    """A connected app's key (`Authorization: Bearer`), for the MCP server only.

    Unknown keys count as failed attempts, as on the REST API; a phone's `full` key is
    refused, so every app with access is listed and revocable on its own.
    """
    redis = getattr(request.app.state, "redis", None)
    failure_key = mcp_failure_key(request)
    if redis is not None:
        await _check_not_blocked(redis, failure_key)

    header = request.headers.get("authorization", "")
    token = header[7:].strip() if header[:7].lower() == "bearer " else ""
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing key")

    key_hash = hash_api_key(token)
    record = (
        await db.execute(select(ApiKey).where(ApiKey.key_hash == key_hash))
    ).scalar_one_or_none()
    if record is None:
        if redis is not None and not await _was_revoked(redis, key_hash):
            await record_failure(redis, failure_key)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid key")
    if record.scope != "read":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Use a connected app's key"
        )

    record.last_used_at = datetime.now(timezone.utc)
    usage_owner.set(record.user_id)
    return record


async def get_current_user_id(
    request: Request,
    api_key: str = Security(api_key_header),
    db: AsyncSession = Depends(get_db),
) -> UUID:
    """Validate API key and return the associated user_id."""
    return (await get_current_api_key(request, api_key=api_key, db=db)).user_id
