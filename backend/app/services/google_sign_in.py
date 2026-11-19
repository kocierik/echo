"""Signing in with Google: the ID token the app got from Google, checked against Google's
public keys and our own client IDs. Blocking (it may fetch the keys): call it off the loop."""

from dataclasses import dataclass

import jwt

from app.core.config import settings
from app.services.passwords import normalize_email

GOOGLE_KEYS_URL = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISSUERS = ("accounts.google.com", "https://accounts.google.com")

# Keys cached in the process; a token signed with a new key fetches them again
_keys = jwt.PyJWKClient(GOOGLE_KEYS_URL, cache_keys=True, timeout=10)


class GoogleUnavailableError(Exception):
    """Google's keys could not be fetched: the token was not judged."""


@dataclass(frozen=True)
class GoogleIdentity:
    subject: str  # Google's stable id for the person ("sub")
    email: str
    given_name: str | None


def client_ids() -> list[str]:
    return [cid.strip() for cid in settings.google_client_ids.split(",") if cid.strip()]


def verify_id_token(token: str, keys: jwt.PyJWKClient = _keys) -> GoogleIdentity:
    """Who the token says the person is. ValueError for any token Google did not sign for
    one of our client IDs, an expired one, or one without a verified email."""
    audience = client_ids()
    if not audience:
        raise ValueError("Google sign-in is not configured")
    try:
        signing_key = keys.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=audience,
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
        )
    except jwt.PyJWKClientConnectionError as error:
        raise GoogleUnavailableError(str(error)) from error
    except jwt.PyJWTError as error:
        raise ValueError(str(error)) from error
    if claims["iss"] not in GOOGLE_ISSUERS:
        raise ValueError("not issued by Google")
    email = claims.get("email")
    if not isinstance(email, str) or not email or claims.get("email_verified") is not True:
        # An unverified email could belong to someone else: never matched to an account
        raise ValueError("no verified email")
    given = claims.get("given_name")
    given = given.strip()[:100] if isinstance(given, str) else ""
    return GoogleIdentity(
        subject=str(claims["sub"]), email=normalize_email(email), given_name=given or None
    )
