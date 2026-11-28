"""Who spoke when in a closed conversation, from pyannoteAI (Paris).

Measured on two AMI meetings (single distant microphone, four people, 2026-11-28): words
given to the wrong person, Deepgram's diarization 9-17%, pyannoteAI precision-2 1-2%. So
when a conversation is read whole again (services/retranscription.py) its audio goes to
pyannoteAI once, and each word takes the speaker speaking while it was said; Deepgram's
own speakers stay as the fallback (no key, an error, a timeout). Names are still Echo's:
each speaker found is recognised from all it said, against the user's own fingerprints.

The audio is uploaded to pyannoteAI's storage (kept there 24-48 h) under a random name.
"""

import asyncio
import logging
import time
import uuid
from dataclasses import replace

import httpx

from app.core.config import settings
from app.services.stt_base import Word
from app.services.usage import record_usage, wav_seconds

logger = logging.getLogger(__name__)

API = "https://api.pyannote.ai/v1"
POLL_SECONDS = 5


async def diarize(
    wav: bytes, transport: httpx.AsyncBaseTransport | None = None
) -> list[dict] | None:
    """[{"speaker", "start", "end"}] for the WAV, or None (off, failed or too slow)."""
    if not settings.pyannote_api_key:
        return None
    headers = {"Authorization": f"Bearer {settings.pyannote_api_key}"}
    try:
        async with httpx.AsyncClient(timeout=120, transport=transport) as client:
            url = f"media://echo/{uuid.uuid4().hex}.wav"
            upload = await client.post(f"{API}/media/input", headers=headers, json={"url": url})
            upload.raise_for_status()
            put = await client.put(
                upload.json()["url"],
                content=wav,
                headers={"Content-Type": "application/octet-stream"},
            )
            put.raise_for_status()
            job = await client.post(
                f"{API}/diarize",
                headers=headers,
                json={"url": url, "model": settings.pyannote_model},
            )
            job.raise_for_status()
            job_id = job.json()["jobId"]
            deadline = time.monotonic() + settings.pyannote_timeout_s
            while time.monotonic() < deadline:
                await asyncio.sleep(POLL_SECONDS)
                got = await client.get(f"{API}/jobs/{job_id}", headers=headers)
                got.raise_for_status()
                data = got.json()
                if data["status"] == "succeeded":
                    await record_usage(
                        "diarization",
                        f"pyannote-{settings.pyannote_model}",
                        input_units=wav_seconds(wav),
                    )
                    return data["output"]["diarization"]
                if data["status"] in ("failed", "canceled"):
                    logger.warning("pyannoteAI job %s %s", job_id, data["status"])
                    return None
            logger.warning("pyannoteAI job %s still running after the timeout", job_id)
    except Exception:
        logger.warning("pyannoteAI diarization failed; Deepgram's speakers stay", exc_info=True)
    return None


def with_speakers(words: list[Word], turns: list[dict]) -> list[Word]:
    """Each word with the speaker who spoke most while it was said (0, 1, … in the order
    they first spoke); a word in no turn takes the nearest one's."""
    if not turns:
        return words
    numbers: dict[str, int] = {}
    for turn in sorted(turns, key=lambda t: t["start"]):
        numbers.setdefault(turn["speaker"], len(numbers))

    def speaker(word: Word) -> int:
        overlap: dict[str, float] = {}
        for turn in turns:
            shared = min(word.end, turn["end"]) - max(word.start, turn["start"])
            if shared > 0:
                overlap[turn["speaker"]] = overlap.get(turn["speaker"], 0.0) + shared
        if overlap:
            return numbers[max(overlap, key=overlap.__getitem__)]
        middle = (word.start + word.end) / 2
        nearest = min(turns, key=lambda t: min(abs(middle - t["start"]), abs(middle - t["end"])))
        return numbers[nearest["speaker"]]

    return [replace(word, speaker=speaker(word)) for word in words]
