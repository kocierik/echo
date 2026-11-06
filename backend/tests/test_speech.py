"""Spoken answers in Echo's natural voices: only the plans with premium_voice (plus,
unlimited); the free plan keeps the phone's own voice."""

import pytest

from app.main import app
from app.models.user import User
from app.routers import speech as speech_router
from app.services import speech
from app.services.plans import get_plan
from tests.conftest import TEST_USER_ID, test_session


class _Speaker:
    def __init__(self, fail=False):
        self.fail = fail
        self.asked: list[tuple[str, str]] = []
        self.languages: list[str | None] = []

    async def speak(self, text, voice, language=None):
        self.asked.append((text, voice))
        self.languages.append(language)
        if self.fail:
            raise speech.SpeechError("The voice could not be made now")
        return b"ID3-mp3"


@pytest.fixture
def speaker():
    fake = _Speaker()
    app.dependency_overrides[speech_router.speaker] = lambda: fake
    yield fake
    app.dependency_overrides.pop(speech_router.speaker, None)


async def _account(plan):
    async with test_session() as db:
        db.add(User(id=TEST_USER_ID, email="erik@example.com", password_hash="x", plan=plan))
        await db.commit()


def test_natural_voices_come_with_plus_and_unlimited():
    assert [bool(get_plan(name).premium_voice) for name in ("free", "plus", "unlimited")] == [
        False, True, True,
    ]


@pytest.mark.parametrize("plan", ["plus", "unlimited"])
async def test_a_premium_plan_gets_the_answer_as_audio(client, auth_headers, speaker, plan):
    await _account(plan)

    response = await client.post(
        "/api/speech", headers=auth_headers,
        json={"text": "Domani hai il dentista.", "voice": "nova"},
    )

    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/mpeg"
    assert response.content == b"ID3-mp3"
    assert speaker.asked == [("Domani hai il dentista.", "nova")]


async def test_the_free_plan_keeps_the_phones_voice(client, auth_headers, speaker):
    await _account("free")

    response = await client.post("/api/speech", headers=auth_headers, json={"text": "Ciao"})
    voices = (await client.get("/api/speech/voices", headers=auth_headers)).json()
    plan = (await client.get("/api/plan", headers=auth_headers)).json()

    assert response.status_code == 403
    assert "Plus" in response.json()["detail"]
    assert speaker.asked == []
    assert voices["available"] is False and voices["voices"]
    assert plan["premium_voice"] is False


async def test_an_unknown_voice_is_the_default_and_a_failure_says_so(client, auth_headers, speaker):
    await _account("unlimited")

    await client.post("/api/speech", headers=auth_headers, json={"text": "Ciao", "voice": "x"})
    speaker.fail = True
    failed = await client.post("/api/speech", headers=auth_headers, json={"text": "Ciao"})

    assert speaker.asked[0] == ("Ciao", speech.DEFAULT_VOICE)
    assert failed.status_code == 503


async def test_too_long_or_empty_is_refused(client, auth_headers, speaker):
    await _account("plus")

    long = await client.post(
        "/api/speech", headers=auth_headers, json={"text": "x" * (speech.MAX_CHARS + 1)}
    )
    empty = await client.post("/api/speech", headers=auth_headers, json={"text": ""})

    assert (long.status_code, empty.status_code) == (422, 422)


async def test_italian_is_spoken_with_an_italian_accent(client, auth_headers, speaker):
    await _account("plus")

    await client.post(
        "/api/speech", headers=auth_headers, json={"text": "Ciao", "language": "it"}
    )

    assert speaker.languages == ["it"]
    assert "Italian accent" in speech.instructions_for("it")
    assert speech.instructions_for(None) == speech.INSTRUCTIONS
