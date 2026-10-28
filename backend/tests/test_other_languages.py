"""The other languages a user hears (Profile → Language): kept on the account, checked,
read back with the main one."""

import uuid

import pytest

from app.core.config import settings
from app.services.language import account_languages
from app.services.passwords import create_user

PASSWORD = "correct horse battery"


@pytest.fixture(autouse=True)
def _open():
    original = settings.registration_open
    settings.registration_open = True
    yield
    settings.registration_open = original


async def _key(client, email, language="it"):
    response = await client.post("/api/auth/register", json={
        "email": email, "password": PASSWORD, "device_name": "Pixel 8",
        "platform": "android", "language": language,
    })
    return {"X-API-Key": response.json()["api_key"]}


async def test_none_until_chosen(client):
    key = await _key(client, "a@x.io")

    assert (await client.get("/api/auth/me", headers=key)).json()["other_languages"] == []


async def test_chosen_in_order_once_without_the_main_one(client):
    key = await _key(client, "b@x.io")

    changed = await client.patch(
        "/api/auth/me", headers=key, json={"other_languages": ["en", "es", "it", "en"]}
    )

    assert changed.status_code == 200
    assert changed.json()["other_languages"] == ["en", "es"]
    assert (await client.get("/api/auth/me", headers=key)).json()["other_languages"] == [
        "en", "es",
    ]


@pytest.mark.parametrize("languages", [["xx"], ["en", "es", "fr", "de", "pt"]])
async def test_an_unknown_language_or_more_than_four_is_refused(client, languages):
    key = await _key(client, f"c{len(languages)}@x.io")

    response = await client.patch("/api/auth/me", headers=key, json={"other_languages": languages})

    assert response.status_code == 422


async def test_a_new_main_language_leaves_the_others(client):
    key = await _key(client, "d@x.io")
    await client.patch("/api/auth/me", headers=key, json={"other_languages": ["en", "es"]})

    changed = await client.patch("/api/auth/me", headers=key, json={"language": "en"})

    assert changed.json()["other_languages"] == ["es"]


async def test_account_languages_reads_both(db_session):
    user = await create_user(db_session, "e@x.io", PASSWORD)
    user.other_languages = ["en", "fr"]
    await db_session.commit()

    assert await account_languages(db_session, user.id) == (settings.stt_language, ["en", "fr"])
    assert await account_languages(db_session, uuid.uuid4()) == (settings.stt_language, [])
