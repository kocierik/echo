"""Signed, expiring OAuth `state` values (CSRF protection for OAuth callbacks).

Format: ``<user_id>.<expires_unix>.<nonce>.<hmac_sha256_hex>``. The callback
verifies the signature and expiry, then consumes the nonce so each state can
be used only once.
"""

import hashlib
import hmac
import secrets
import time
import uuid

STATE_TTL_S = 10 * 60


class InvalidOAuthStateError(Exception):
    """The state is malformed, forged, expired or already used."""


def _sign(payload: str, secret: str) -> str:
    return hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()


def create_state(user_id: uuid.UUID, secret: str, now: float | None = None) -> str:
    if not secret:
        raise ValueError("OAuth state secret is not configured")
    expires = int((now if now is not None else time.time()) + STATE_TTL_S)
    payload = f"{user_id}.{expires}.{secrets.token_urlsafe(16)}"
    return f"{payload}.{_sign(payload, secret)}"


def verify_state(state: str, secret: str, now: float | None = None) -> tuple[uuid.UUID, str]:
    """Return (user_id, nonce) for a valid state, or raise InvalidOAuthStateError."""
    if not secret:
        raise InvalidOAuthStateError("OAuth state secret is not configured")
    try:
        user_part, expires_part, nonce, signature = state.split(".")
        user_id = uuid.UUID(user_part)
        expires = int(expires_part)
    except (AttributeError, ValueError) as exc:
        raise InvalidOAuthStateError("malformed state") from exc

    payload = f"{user_part}.{expires_part}.{nonce}"
    if not hmac.compare_digest(signature, _sign(payload, secret)):
        raise InvalidOAuthStateError("bad signature")
    if (now if now is not None else time.time()) > expires:
        raise InvalidOAuthStateError("expired state")
    return user_id, nonce
