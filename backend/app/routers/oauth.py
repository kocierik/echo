"""OAuth2 callback router for third-party integrations (Google, etc.)."""

import html
import logging
import uuid
from urllib.parse import urlencode

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.config import settings
from app.core.database import get_db
from app.core.oauth_state import STATE_TTL_S, InvalidOAuthStateError, create_state, verify_state
from app.models.integration import Integration

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/integrations/oauth", tags=["oauth"])

# Google OAuth2 endpoints
GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_SCOPES = "https://www.googleapis.com/auth/calendar.events"


@router.get("/google_calendar/authorize")
@router.get("/google/authorize")
async def google_authorize(user_id: uuid.UUID = Depends(get_current_user_id)):
    """Generate Google OAuth2 authorization URL.

    The mobile app opens this URL in a browser. After the user approves,
    Google redirects to our callback endpoint.
    """
    if not settings.google_client_id or not settings.google_client_secret:
        raise HTTPException(status_code=503, detail="Google OAuth not configured")

    redirect_uri = settings.google_redirect_uri
    if not redirect_uri:
        raise HTTPException(status_code=503, detail="Google redirect URI not configured")

    # Signed, expiring, single-use state links the callback back to this user
    # and prevents a third party from attaching their Google account (CSRF).
    state = create_state(user_id, settings.effective_oauth_state_secret)
    query = urlencode({
        "client_id": settings.google_client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": GOOGLE_SCOPES,
        "access_type": "offline",
        "prompt": "consent",
        "state": state,
    })
    return {"authorize_url": f"{GOOGLE_AUTH_URL}?{query}"}


@router.get("/google/callback")
async def google_callback(
    request: Request,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    db: AsyncSession = Depends(get_db),
):
    """Handle Google OAuth2 callback.

    Google redirects here after user approves. We verify the signed state,
    exchange the code for tokens and save them as the integration config.
    """
    if error:
        message = f"Google returned an error: {html.escape(error)}"
        return _failure_page(message)

    if not code or not state:
        return _failure_page("Missing authorization code.")

    try:
        user_id, nonce = verify_state(state, settings.effective_oauth_state_secret)
        first_use = await request.app.state.redis.set(
            f"oauth:state:{nonce}", "1", nx=True, ex=STATE_TTL_S
        )
    except InvalidOAuthStateError as exc:
        logger.warning(f"[Google OAuth] Rejected state: {exc}")
        first_use = False
    if not first_use:
        return _failure_page(
            "This authorization link is invalid or expired. "
            "Start the connection again from Echo."
        )

    # Exchange code for tokens
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                GOOGLE_TOKEN_URL,
                data={
                    "code": code,
                    "client_id": settings.google_client_id,
                    "client_secret": settings.google_client_secret,
                    "redirect_uri": settings.google_redirect_uri,
                    "grant_type": "authorization_code",
                },
            )
            if resp.status_code != 200:
                logger.error(f"[Google OAuth] Token exchange failed: {resp.text}")
                return _failure_page("Could not get tokens from Google.")

            tokens = resp.json()
    except Exception as e:
        logger.error(f"[Google OAuth] Token exchange error: {e}")
        return _failure_page("Network error during authorization.")

    refresh_token = tokens.get("refresh_token")
    access_token = tokens.get("access_token")

    if not refresh_token and not access_token:
        return _failure_page("No token received.")

    # Save or update integration
    result = await db.execute(
        select(Integration)
        .where(Integration.user_id == user_id)
        .where(Integration.provider == "google_calendar")
    )
    integration = result.scalar_one_or_none()

    config = {
        "access_token": access_token,
        # Google sends a refresh token only on first consent: keep the stored one
        "refresh_token": refresh_token
        or (integration.config.get("refresh_token") if integration else None),
        "token_type": tokens.get("token_type", "Bearer"),
    }

    if integration:
        integration.config = config
        integration.enabled = True
    else:
        integration = Integration(
            user_id=user_id,
            provider="google_calendar",
            enabled=True,
            config=config,
            entity_types=["event"],
        )
        db.add(integration)

    await db.commit()
    logger.info(f"[Google OAuth] Connected for user {user_id}")

    return HTMLResponse(_result_page(
        "Connected!",
        "Google Calendar is now connected to Echo. You can close this page.",
        success=True,
    ))


def _failure_page(message: str) -> HTMLResponse:
    return HTMLResponse(_result_page("Connection Failed", message, success=False))


def _result_page(title: str, message: str, success: bool) -> str:
    """Minimal HTML page shown after OAuth callback."""
    color = "#22c55e" if success else "#ef4444"
    icon = "✓" if success else "✗"
    return f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>
body {{ font-family: -apple-system, system-ui, sans-serif; display: flex;
  justify-content: center; align-items: center; min-height: 100vh; margin: 0;
  background: #0a0a0a; color: #fff; }}
.card {{ text-align: center; padding: 48px; border-radius: 20px; background: #1a1a1a;
  max-width: 400px; }}
.icon {{ font-size: 64px; margin-bottom: 16px; color: {color}; }}
h1 {{ font-size: 24px; margin-bottom: 8px; }}
p {{ color: #888; font-size: 14px; }}
</style></head>
<body><div class="card"><div class="icon">{icon}</div>
<h1>{title}</h1><p>{message}</p></div></body></html>"""
