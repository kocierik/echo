"""A closed conversation transcribed again whole, its words split back into its segments.

Each segment (a sentence or two, cut by the wearable at a pause) is transcribed alone as
it arrives, so that "Ehi Echo" is answered at once. Alone, a segment has no sentences
around it: the speech-to-text guesses words and even the language ("Siems five years"
was "since five years"). Once the conversation is closed (quiet for the silence timeout)
its segments' audio goes once more as one recording, with a short silence between them,
and each word goes back to the segment it was said in. When a text changed, the
conversation is analysed again (people, promises, title and summary) as after a
correction by hand.
"""

import io
import json
import logging
import uuid
import wave
from datetime import datetime, timedelta
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import settings
from app.models.conversation import Conversation
from app.models.segment import Segment
from app.services.adpcm_decoder import CHANNELS, SAMPLE_RATE, SAMPLE_WIDTH, decode_adpcm
from app.services.language import account_languages
from app.services.stt_base import STTService, Word
from app.services.transcription_enhancer import (
    build_stt_context,
    clean_transcription,
    speaker_prefix,
)

logger = logging.getLogger(__name__)

# Between two segments in the joined recording: a pause, so words do not run together
GAP_SECONDS = 0.5


def split_words(words: list[Word], spans: list[tuple[float, float]]) -> list[str]:
    """The text of each span (start, end in seconds, in order): every word goes to the
    span its middle falls in, else to the nearest one (a word said across a cut)."""
    texts: list[list[str]] = [[] for _ in spans]
    for word in words:
        middle = (word.start + word.end) / 2
        nearest = min(
            range(len(spans)),
            key=lambda i: 0 if spans[i][0] <= middle < spans[i][1]
            else min(abs(middle - spans[i][0]), abs(middle - spans[i][1])),
        )
        texts[nearest].append(word.text)
    return [" ".join(parts) for parts in texts]


def _joined_wav(pcms: list[bytes]) -> tuple[bytes, list[tuple[float, float]]]:
    """One WAV of the segments' audio with a pause between them, and where each one is."""
    bytes_per_second = SAMPLE_RATE * SAMPLE_WIDTH * CHANNELS
    gap = b"\0" * int(GAP_SECONDS * bytes_per_second)
    joined = bytearray()
    spans: list[tuple[float, float]] = []
    for pcm in pcms:
        if joined:
            joined += gap
        start = len(joined) / bytes_per_second
        joined += pcm
        spans.append((start, len(joined) / bytes_per_second))
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(CHANNELS)
        wav.setsampwidth(SAMPLE_WIDTH)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(bytes(joined))
    return buffer.getvalue(), spans


async def retranscribe(db: AsyncSession, conversation: Conversation, stt: STTService) -> bool:
    """The conversation's segments transcribed again as one recording; True when a
    segment's text changed. A conversation of one segment, or whose audio is gone,
    stays as it is."""
    segments = list(await db.scalars(
        select(Segment)
        .options(selectinload(Segment.transcription))
        .where(Segment.conversation_id == conversation.id)
        .where(Segment.transcription_status == "completed")
        .order_by(Segment.recorded_at)
    ))
    segments = [
        s for s in segments
        if s.transcription is not None and s.audio_path and Path(s.audio_path).exists()
    ]
    if len(segments) < 2:
        return False

    wav, spans = _joined_wav([decode_adpcm(Path(s.audio_path).read_bytes()) for s in segments])
    stt_context = await build_stt_context(db, conversation.user_id)
    language, others = await account_languages(db, conversation.user_id)
    result = await stt.transcribe(
        wav,
        language=language,
        also=others or None,
        prompt=stt_context.prompt or None,
        keyterms=stt_context.keyterms,
    )
    if not result.words:
        return False  # a service without word times (OpenAI): the segments stay

    changed = False
    for segment, text in zip(segments, split_words(result.words, spans)):
        text = clean_transcription(text)
        if not text:
            continue  # nothing heard here this time: what was heard before stays
        new = f"{speaker_prefix(segment.speaker)}{text}"
        if new != segment.transcription.text:
            segment.transcription.text = new
            segment.transcription.language = result.language
            changed = True
    return changed


def closed_before(now: datetime) -> datetime:
    """A conversation quiet since before this is closed (as for its summary)."""
    return now - timedelta(milliseconds=settings.silence_timeout_ms)


async def conversations_to_retranscribe(db: AsyncSession, now: datetime, limit: int):
    """Closed, analysed, not yet transcribed again; the oldest first."""
    return list(await db.scalars(
        select(Conversation)
        .where(Conversation.retranscribed_at.is_(None))
        .where(Conversation.analysis_status == "completed")
        .where(func.coalesce(Conversation.ended_at, Conversation.started_at) < closed_before(now))
        .order_by(Conversation.started_at.asc())
        .limit(limit)
        .with_for_update(skip_locked=True)
    ))


async def mark_reanalysis(redis_client, conversation_id: uuid.UUID, now: datetime) -> None:
    """Queues the conversation's analysis again, as a correction by hand does."""
    requested_at = now.isoformat()
    await redis_client.set(f"reanalysis:latest:{conversation_id}", requested_at)
    await redis_client.lpush(
        "queue:reanalysis",
        json.dumps({"conversation_id": str(conversation_id), "requested_at": requested_at}),
    )
