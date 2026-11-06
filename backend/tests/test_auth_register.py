"""Creating an account from the app: open unless REGISTRATION_OPEN is false."""

import pytest
from sqlalchemy import select

from app.core.config import settings
from app.models.user import User

PASSWORD = "correct horse battery"


def _register(email="ada@example.com", password=PASSWORD, name="Pixel 8", platform="android"):
    return {"email": email, "password": password, "device_name": name, "platform": platform}


@pytest.fixture(autouse=True)
def _open():
    original = settings.registration_open
    settings.registration_open = True
    yield
    settings.registration_open = original


async def test_register_creates_an_account_and_signs_this_phone_in(client, db_session):
    response = await client.post("/api/auth/register", json=_register(email=" Ada@Example.com "))

    assert response.status_code == 200
    body = response.json()
    assert body["user"]["email"] == "ada@example.com"
    works = await client.get("/api/conversations", headers={"X-API-Key": body["api_key"]})
    assert works.status_code == 200
    assert works.json()["total"] == 0  # a new account starts empty
    again = await client.post(
        "/api/auth/login",
        json={"email": "ada@example.com", "password": PASSWORD, "device_name": "iPhone",
              "platform": "ios"},
    )
    assert again.status_code == 200


async def test_an_email_with_an_account_says_sign_in(client, db_session):
    await client.post("/api/auth/register", json=_register())

    response = await client.post("/api/auth/register", json=_register(email="ADA@example.com"))

    assert response.status_code == 409
    assert response.json()["detail"] == (
        "An account with this email already exists. Sign in instead."
    )


async def test_bad_email_and_empty_password_are_explained(client, db_session):
    bad = await client.post("/api/auth/register", json=_register(email="ada.example.com"))
    empty = await client.post("/api/auth/register", json=_register(password=""))

    assert bad.status_code == 400
    assert bad.json()["detail"] == "Enter a valid email."
    # Refused by the request's own schema (422) or by the check (400)
    assert empty.status_code in (400, 422)
    assert (await db_session.scalars(select(User))).all() == []


async def test_any_password_for_now_and_a_minimum_when_set(client, monkeypatch):
    short = await client.post("/api/auth/register", json=_register(password="abc"))
    assert short.status_code in (200, 201)

    monkeypatch.setattr("app.routers.auth.settings.min_password_length", 10)
    longer = await client.post(
        "/api/auth/register", json=_register(email="bea@example.com", password="short")
    )
    assert longer.json()["detail"] == "Use at least 10 characters for the password."


async def test_registration_can_be_closed(client, db_session):
    settings.registration_open = False

    response = await client.post("/api/auth/register", json=_register())

    assert response.status_code == 403
    assert response.json()["detail"] == "Registration is closed."


async def test_registrations_are_limited_per_address(client, db_session):
    home = {"CF-Connecting-IP": "198.51.100.30"}
    for i in range(5):
        made = await client.post(
            "/api/auth/register", json=_register(email=f"user{i}@example.com"), headers=home
        )
        assert made.status_code == 200

    sixth = await client.post(
        "/api/auth/register", json=_register(email="user5@example.com"), headers=home
    )

    assert sixth.status_code == 429
    assert sixth.json()["detail"].startswith("Too many accounts from here.")


async def test_a_registered_account_gets_the_plan_of_the_settings(
    client, db_session, monkeypatch
):
    monkeypatch.setattr(settings, "new_account_plan", "unlimited")

    response = await client.post("/api/auth/register", json=_register())

    assert response.status_code == 200
    user = await db_session.scalar(select(User).where(User.email == "ada@example.com"))
    assert user.plan == "unlimited"
