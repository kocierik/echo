"""pyannoteAI diarization: the upload and job, and each word's speaker from its turns."""

import json

import httpx

from app.core.config import settings
from app.services import diarization
from app.services.diarization import diarize, with_speakers
from app.services.stt_base import Word

TURNS = [
    {"speaker": "SPEAKER_01", "start": 0.0, "end": 2.0},
    {"speaker": "SPEAKER_00", "start": 2.0, "end": 4.0},
]


def test_each_word_takes_who_spoke_most_while_it_was_said():
    words = [Word("a", 0.1, 0.5, 0), Word("b", 1.8, 2.6, 0), Word("c", 4.5, 4.8, 0)]

    assert [w.speaker for w in with_speakers(words, TURNS)] == [0, 1, 1]
    assert with_speakers(words, []) == words


async def test_off_without_a_key(monkeypatch):
    monkeypatch.setattr(settings, "pyannote_api_key", "")
    assert await diarize(b"wav") is None


async def test_uploads_runs_and_reads_the_job(monkeypatch):
    monkeypatch.setattr(settings, "pyannote_api_key", "k")
    monkeypatch.setattr(diarization, "POLL_SECONDS", 0)
    seen = []

    def answer(request: httpx.Request) -> httpx.Response:
        seen.append((request.method, request.url.path))
        if request.url.path == "/v1/media/input":
            return httpx.Response(201, json={"url": "https://upload.example/put"})
        if request.url.path == "/put":
            return httpx.Response(200)
        if request.url.path == "/v1/diarize":
            body = json.loads(request.content)
            assert body["model"] == settings.pyannote_model
            assert body["url"].startswith("media://echo/")
            return httpx.Response(200, json={"jobId": "j1", "status": "created"})
        return httpx.Response(200, json={"status": "succeeded", "output": {"diarization": TURNS}})

    turns = await diarize(b"wav", transport=httpx.MockTransport(answer))

    assert turns == TURNS
    assert [path for _, path in seen] == ["/v1/media/input", "/put", "/v1/diarize", "/v1/jobs/j1"]


async def test_a_failure_leaves_deepgrams_speakers(monkeypatch):
    monkeypatch.setattr(settings, "pyannote_api_key", "k")

    def refuse(request: httpx.Request) -> httpx.Response:
        return httpx.Response(402, json={"message": "subscription required"})

    assert await diarize(b"wav", transport=httpx.MockTransport(refuse)) is None
