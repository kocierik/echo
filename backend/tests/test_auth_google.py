"""Signing in with Google: the ID token checked against Google's keys and our client IDs,
then the person's account found by Google id, linked by verified email, or made new."""

import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from sqlalchemy import select

from app.core.config import settings
from app.models.user import User
from app.routers import auth as auth_router
from app.services import google_sign_in
from app.services.google_sign_in import GoogleIdentity, GoogleUnavailableError, verify_id_token
from app.services.passwords import create_user

CLIENT = "ios-client.apps.googleusercontent.com"
PASSWORD = "correct horse battery"


@pytest.fixture(autouse=True)
def _configured():
    original = (settings.google_client_ids, settings.registration_open)
    settings.google_client_ids = f"{CLIENT}, web-client.apps.googleusercontent.com"
    settings.registration_open = True
    yield
    settings.google_client_ids, settings.registration_open = original


# --- the token check --------------------------------------------------------------------

_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _Keys:
    """Google's key set, with our test key in it."""

    def get_signing_key_from_jwt(self, token):
        return jwt.PyJWK.from_dict(
            {**jwt.algorithms.RSAAlgorithm.to_jwk(_KEY.public_key(), as_dict=True),
             "kid": "k1", "alg": "RS256"}
        )


def _token(**claims) -> str:
    now = int(time.time())
    body = {
        "iss": "https://accounts.google.com", "aud": CLIENT, "sub": "g-123",
        "email": "Ada@Example.com", "email_verified": True, "given_name": " Ada ",
        "iat": now, "exp": now + 600,
    }
    body.update(claims)
    body = {k: v for k, v in body.items() if v is not None}
    return jwt.encode(body, _KEY, algorithm="RS256", headers={"kid": "k1"})


def test_a_good_token_says_who_it_is():
    person = verify_id_token(_token(), keys=_Keys())

    assert person == GoogleIdentity(subject="g-123", email="ada@example.com", given_name="Ada")


@pytest.mark.parametrize("claims", [
    {"aud": "someone-elses-app"},
    {"iss": "https://evil.example.com"},
    {"exp": int(time.time()) - 60},
    {"email_verified": False},
    {"email": None},
])
def test_tokens_we_do_not_accept(claims):
    with pytest.raises(ValueError):
        verify_id_token(_token(**claims), keys=_Keys())


def test_a_token_signed_by_another_key_is_refused():
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    forged = jwt.encode(
        {"iss": "accounts.google.com", "aud": CLIENT, "sub": "x", "email": "a@b.c",
         "email_verified": True, "iat": int(time.time()), "exp": int(time.time()) + 600},
        other, algorithm="RS256", headers={"kid": "k1"},
    )
    with pytest.raises(ValueError):
        verify_id_token(forged, keys=_Keys())


def test_without_client_ids_nothing_is_accepted():
    settings.google_client_ids = ""
    with pytest.raises(ValueError):
        verify_id_token(_token(), keys=_Keys())


# --- the endpoint -------------------------------------------------------------------------


def _google_says(monkeypatch, subject="g-123", email="ada@example.com", name="Ada"):
    """Google vouches for this person for any token."""
    monkeypatch.setattr(
        auth_router, "verify_id_token",
        lambda token: GoogleIdentity(subject=subject, email=email, given_name=name),
    )


def _body(platform="ios", language=None):
    return {"id_token": "t", "device_name": "iPhone", "platform": platform,
            "language": language}


async def test_a_new_person_gets_an_account_without_a_password(client, db_session, monkeypatch):
    _google_says(monkeypatch)

    response = await client.post("/api/auth/google", json=_body(language="it-IT"))

    assert response.status_code == 200
    body = response.json()
    assert body["user"]["email"] == "ada@example.com"
    user = await db_session.scalar(select(User).where(User.email == "ada@example.com"))
    assert (user.google_subject, user.password_hash, user.name, user.language) == (
        "g-123", "", "Ada", "it"
    )
    me = await client.get("/api/auth/me", headers={"X-API-Key": body["api_key"]})
    assert me.json()["has_password"] is False
    # No password to sign in with
    login = await client.post("/api/auth/login", json={
        "email": "ada@example.com", "password": "echo-no-such-account",
        "device_name": "x", "platform": "ios"})
    assert login.status_code == 401


async def test_the_same_person_signs_in_to_the_same_account(client, db_session, monkeypatch):
    _google_says(monkeypatch)
    first = await client.post("/api/auth/google", json=_body())
    # The Gmail address changed; Google's id did not
    _google_says(monkeypatch, email="ada.lovelace@example.com")

    again = await client.post("/api/auth/google", json=_body(platform="web"))

    assert again.json()["user"]["id"] == first.json()["user"]["id"]
    assert len((await db_session.scalars(select(User))).all()) == 1


async def test_a_password_account_with_that_email_is_linked(client, db_session, monkeypatch):
    user = await create_user(db_session, "ada@example.com", PASSWORD)
    _google_says(monkeypatch)

    response = await client.post("/api/auth/google", json=_body())

    assert response.json()["user"]["id"] == str(user.id)
    await db_session.refresh(user)
    assert user.google_subject == "g-123"
    # The password still works too
    login = await client.post("/api/auth/login", json={
        "email": "ada@example.com", "password": PASSWORD, "device_name": "x", "platform": "ios"})
    assert login.status_code == 200


async def test_closed_registration_makes_no_account_but_links(client, db_session, monkeypatch):
    settings.registration_open = False
    _google_says(monkeypatch)

    new = await client.post("/api/auth/google", json=_body())
    await create_user(db_session, "ada@example.com", PASSWORD)
    existing = await client.post("/api/auth/google", json=_body())

    assert new.status_code == 403
    assert existing.status_code == 200


async def test_a_refused_token_is_401_and_google_down_is_503(client, monkeypatch):
    def refuse(token):
        raise ValueError("bad")

    def down(token):
        raise GoogleUnavailableError("timeout")

    monkeypatch.setattr(auth_router, "verify_id_token", refuse)
    refused = await client.post("/api/auth/google", json=_body())
    monkeypatch.setattr(auth_router, "verify_id_token", down)
    unreachable = await client.post("/api/auth/google", json=_body())

    assert refused.status_code == 401
    assert refused.json()["detail"] == "Google did not confirm who you are."
    assert unreachable.status_code == 503


async def test_off_without_client_ids(client):
    settings.google_client_ids = ""

    response = await client.post("/api/auth/google", json=_body())

    assert response.status_code == 404


async def test_a_google_account_is_deleted_by_confirming_with_google(
    client, db_session, monkeypatch
):
    _google_says(monkeypatch)
    signed_in = (await client.post("/api/auth/google", json=_body())).json()
    headers = {"X-API-Key": signed_in["api_key"]}

    no_password = await client.post("/api/auth/me/delete", json={"password": "x"},
                                    headers=headers)
    _google_says(monkeypatch, subject="someone-else")
    wrong_person = await client.post("/api/auth/me/delete", json={"google_id_token": "t"},
                                     headers=headers)
    _google_says(monkeypatch)
    deleted = await client.post("/api/auth/me/delete", json={"google_id_token": "t"},
                                headers=headers)

    assert no_password.status_code == 403
    assert wrong_person.status_code == 403
    assert deleted.status_code == 204
    assert (await db_session.scalars(select(User))).all() == []


def test_the_module_keys_client_points_at_google():
    assert google_sign_in._keys.uri == google_sign_in.GOOGLE_KEYS_URL
