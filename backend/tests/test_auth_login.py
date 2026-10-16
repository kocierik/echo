"""Signing in gives a phone its own key; signing out and revoking take it away."""

import asyncio

from sqlalchemy import select

from app.core import auth
from app.models.api_key import ApiKey
from app.services.passwords import create_user
from tests.conftest import TEST_USER_ID

EMAIL = "erik@example.com"
PASSWORD = "correct horse battery"


async def _owner(db_session):
    return await create_user(db_session, EMAIL, PASSWORD, user_id=TEST_USER_ID)


def _login(email=EMAIL, password=PASSWORD, name="iPhone", platform="ios"):
    return {"email": email, "password": password, "device_name": name, "platform": platform}


async def test_login_issues_a_key_that_works(client, db_session):
    await _owner(db_session)

    response = await client.post("/api/auth/login", json=_login())

    assert response.status_code == 200
    body = response.json()
    assert body["user"] == {"id": str(TEST_USER_ID), "email": EMAIL}
    key = body["api_key"]
    assert len(key) >= 40
    works = await client.get("/api/conversations", headers={"X-API-Key": key})
    assert works.status_code == 200
    row = await db_session.scalar(select(ApiKey).where(ApiKey.key_hash == auth.hash_api_key(key)))
    assert row is not None
    assert str(row.id) == body["device_id"]
    assert (row.name, row.platform, row.user_id) == ("iPhone", "ios", TEST_USER_ID)


async def test_login_wrong_password_and_unknown_email_look_the_same(client, db_session):
    await _owner(db_session)

    wrong = await client.post("/api/auth/login", json=_login(password="not the password"))
    unknown = await client.post("/api/auth/login", json=_login(email="nobody@example.com"))

    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json() == unknown.json() == {"detail": "Wrong email or password."}


async def test_login_email_is_case_and_space_insensitive(client, db_session):
    await _owner(db_session)

    response = await client.post("/api/auth/login", json=_login(email="  Erik@Example.COM "))

    assert response.status_code == 200


async def test_login_rejects_a_platform_it_does_not_know(client, db_session):
    await _owner(db_session)

    response = await client.post("/api/auth/login", json=_login(platform="windows"))

    assert response.status_code == 422


async def test_login_limited_per_client(client, db_session):
    await _owner(db_session)
    for _ in range(auth.AUTH_FAILURE_LIMIT):
        response = await client.post("/api/auth/login", json=_login(password="wrong one"))
        assert response.status_code == 401

    blocked = await client.post("/api/auth/login", json=_login())

    assert blocked.status_code == 429
    assert blocked.json()["detail"] == "Too many attempts. Try again in 15 minutes."
    assert blocked.headers["Retry-After"] == str(auth.AUTH_FAILURE_WINDOW_SECONDS)


async def test_login_limited_per_email_across_clients(client, db_session):
    await _owner(db_session)
    for attempt in range(auth.AUTH_FAILURE_LIMIT):
        response = await client.post(
            "/api/auth/login",
            json=_login(password="wrong one"),
            headers={"CF-Connecting-IP": f"203.0.113.{attempt}"},
        )
        assert response.status_code == 401

    same_email = await client.post(
        "/api/auth/login", json=_login(), headers={"CF-Connecting-IP": "198.51.100.7"}
    )
    other_email = await client.post(
        "/api/auth/login",
        json=_login(email="ada@example.com"),
        headers={"CF-Connecting-IP": "198.51.100.8"},
    )

    assert same_email.status_code == 429
    assert other_email.status_code == 401


async def test_logout_deletes_only_the_calling_key(client, db_session):
    await _owner(db_session)
    first = (await client.post("/api/auth/login", json=_login())).json()["api_key"]
    second = (await client.post("/api/auth/login", json=_login(name="iPad"))).json()["api_key"]

    out = await client.post("/api/auth/logout", headers={"X-API-Key": first})

    assert out.status_code == 204
    gone = await client.get("/api/conversations", headers={"X-API-Key": first})
    kept = await client.get("/api/conversations", headers={"X-API-Key": second})
    assert gone.status_code == 401
    assert kept.status_code == 200


async def test_devices_lists_own_keys_and_marks_current(client, db_session):
    await _owner(db_session)
    await create_user(db_session, "ada@example.com", "another long password")
    phone = (await client.post("/api/auth/login", json=_login())).json()["api_key"]
    await client.post("/api/auth/login", json=_login(name="Pixel", platform="android"))
    await client.post(
        "/api/auth/login",
        json=_login(email="ada@example.com", password="another long password", name="Ada"),
    )

    response = await client.get("/api/auth/devices", headers={"X-API-Key": phone})

    assert response.status_code == 200
    devices = response.json()
    names = {d["name"] for d in devices}
    # The conftest's own key belongs to the owner too
    assert {"iPhone", "Pixel"} <= names and "Ada" not in names
    assert [d["current"] for d in devices if d["name"] == "iPhone"] == [True]
    assert all(not d["current"] for d in devices if d["name"] != "iPhone")
    assert all(set(d) == {"id", "name", "platform", "created_at", "last_used_at", "current"}
               for d in devices)


async def test_revoke_other_device_and_404_for_foreign_id(client, db_session):
    await _owner(db_session)
    await create_user(db_session, "ada@example.com", "another long password")
    phone = (await client.post("/api/auth/login", json=_login())).json()["api_key"]
    pixel = (await client.post("/api/auth/login", json=_login(name="Pixel"))).json()
    ada = (
        await client.post(
            "/api/auth/login",
            json=_login(email="ada@example.com", password="another long password"),
        )
    ).json()
    headers = {"X-API-Key": phone}

    revoked = await client.delete(f"/api/auth/devices/{pixel['device_id']}", headers=headers)
    foreign = await client.delete(f"/api/auth/devices/{ada['device_id']}", headers=headers)

    assert revoked.status_code == 204
    assert foreign.status_code == 404
    pixel_now = await client.get("/api/conversations", headers={"X-API-Key": pixel["api_key"]})
    ada_now = await client.get("/api/conversations", headers={"X-API-Key": ada["api_key"]})
    assert pixel_now.status_code == 401
    assert ada_now.status_code == 200


async def test_concurrent_wrong_logins_are_limited(client, db_session):
    await _owner(db_session)

    answers = await asyncio.gather(
        *[client.post("/api/auth/login", json=_login(password=f"wrong {i}")) for i in range(30)]
    )

    codes = [a.status_code for a in answers]
    assert codes.count(401) <= auth.AUTH_FAILURE_LIMIT
    assert codes.count(429) >= 30 - auth.AUTH_FAILURE_LIMIT


async def test_a_revoked_phone_can_sign_in_again_from_the_same_address(client, db_session):
    await _owner(db_session)
    home = {"CF-Connecting-IP": "198.51.100.20"}
    phone = (await client.post("/api/auth/login", json=_login(), headers=home)).json()
    other = (
        await client.post("/api/auth/login", json=_login(name="Pixel"), headers=home)
    ).json()["api_key"]
    await client.delete(
        f"/api/auth/devices/{phone['device_id']}", headers={"X-API-Key": other} | home
    )

    # The revoked phone, still open, fires a burst of requests with its dead key
    for _ in range(auth.AUTH_FAILURE_LIMIT + 3):
        dead = await client.get(
            "/api/conversations", headers={"X-API-Key": phone["api_key"]} | home
        )
        assert dead.status_code == 401

    again = await client.post("/api/auth/login", json=_login(), headers=home)
    neighbour = await client.get("/api/conversations", headers={"X-API-Key": other} | home)
    assert again.status_code == 200
    assert neighbour.status_code == 200


async def test_a_blank_device_name_is_rejected(client, db_session):
    await _owner(db_session)

    response = await client.post("/api/auth/login", json=_login(name="   "))

    assert response.status_code == 422
