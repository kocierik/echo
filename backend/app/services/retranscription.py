"""A closed conversation transcribed again whole, its words split back into its segments.

Each segment (a sentence or two, cut by the wearable at a pause) is transcribed alone as
it arrives, so that "Ehi Echo" is answered at once. Alone, a segment has no sentences
around it: the speech-to-text guesses words and even the language ("Siems five years"
was "since five years"). Once the conversation is closed (quiet for the silence timeout)
its segments' audio goes once more as one recording, with a short silence between them,
and each word goes back to the segment it was said in. When a text changed, the
conversation is analysed again (people, promises, title and summary) as after a
correction by hand.

Asked with each word's speaker, it also tells apart the voices of a segment (up to 25 s,
several people can speak in it): each voice is recognised from its own audio, and a
segment where more than one spoke keeps its turns, who said what.
"""

import json
import logging
import uuid
from datetime import datetime, timedelta
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import settings
from app.models.conversation import Conversation
from app.models.segment import Segment
from app.services.adpcm_decoder import CHANNELS, SAMPLE_RATE, SAMPLE_WIDTH
from app.services.language import account_languages
from app.services.segment_audio import decode_segment, pcm_to_wav
from app.services.stt_base import STTService, Word
from app.services.transcription_enhancer import (
    build_stt_context,
    clean_transcription,
    speaker_prefix,
)
from app.services.voice_embedding import embed_voice
from app.services.voice_profiles import best_match, list_profiles, number_unknown_voices

logger = logging.getLogger(__name__)

# Between two segments in the joined recording: a pause, so words do not run together
GAP_SECONDS = 0.5
# A conversation of one segment shorter than this is left as it is: one voice, most likely
LONE_SEGMENT_MS = 10_000
BYTES_PER_SECOND = SAMPLE_RATE * SAMPLE_WIDTH * CHANNELS


def assign_words(words: list[Word], spans: list[tuple[float, float]]) -> list[list[Word]]:
    """The words of each span (start, end in seconds, in order): every word goes to the
    span its middle falls in, else to the nearest one (a word said across a cut)."""
    parts: list[list[Word]] = [[] for _ in spans]
    for word in words:
        middle = (word.start + word.end) / 2
        nearest = min(
            range(len(spans)),
            key=lambda i: 0 if spans[i][0] <= middle < spans[i][1]
            else min(abs(middle - spans[i][0]), abs(middle - spans[i][1])),
        )
        parts[nearest].append(word)
    return parts


def split_words(words: list[Word], spans: list[tuple[float, float]]) -> list[str]:
    """The text of each span, as `assign_words` splits the words."""
    return [" ".join(w.text for w in part) for part in assign_words(words, spans)]


def _joined(pcms: list[bytes]) -> tuple[bytes, list[tuple[float, float]]]:
    """The segments' audio with a pause between them, and where each one is."""
    gap = b"\0" * int(GAP_SECONDS * BYTES_PER_SECOND)
    joined = bytearray()
    spans: list[tuple[float, float]] = []
    for pcm in pcms:
        if joined:
            joined += gap
        start = len(joined) / BYTES_PER_SECOND
        joined += pcm
        spans.append((start, len(joined) / BYTES_PER_SECOND))
    return bytes(joined), spans


def _at(seconds: float) -> int:
    """The byte of the joined audio at `seconds` (on a sample)."""
    return int(seconds * SAMPLE_RATE) * SAMPLE_WIDTH * CHANNELS


async def _voices(db, conversation, segments, parts, pcm) -> dict:
    """Who each speaker is, recognised from all they said:
    {speaker: {"speaker": "self"|"other", "profile_id": str|None, "group": int|None}}."""
    profiles = await list_profiles(db, conversation.user_id)
    has_self = any(p.is_self for p in profiles)
    words = [w for part in parts for w in part]
    voices: dict = {}
    unknown: list = []
    for speaker in dict.fromkeys(w.speaker for w in words):  # in the order they spoke
        audio = b"".join(pcm[_at(w.start):_at(w.end)] for w in words if w.speaker == speaker)
        embedding = await embed_voice(pcm_to_wav(audio))
        match = best_match(profiles, embedding) if embedding is not None else None
        voice = {"speaker": "other", "profile_id": None, "group": None}
        if match is not None and match.similarity >= settings.voice_match_threshold:
            voice["speaker"] = "self" if match.profile.is_self else "other"
            voice["profile_id"] = str(match.profile.id)
        elif not has_self and _mostly_self(speaker, segments, parts):
            voice["speaker"] = "self"  # no own voice yet: as the loudness rule said
        else:
            unknown.append(speaker)
        voices[speaker] = voice
    if len(unknown) >= 2:  # one unknown voice is "Other", several "Person 2", "Person 3"
        for number, speaker in enumerate(unknown, start=2):
            voices[speaker]["group"] = number
    return voices


def _mostly_self(speaker, segments, parts) -> bool:
    """Most of the speaker's words are in segments the loudness rule said were the user's."""
    said = [s.speaker for s, part in zip(segments, parts) for w in part if w.speaker == speaker]
    return said.count("self") * 2 > len(said)


def _turns(words: list[Word], voices: dict) -> list[dict]:
    """The words one voice said in a row as one turn."""
    turns: list[dict] = []
    for word in words:
        voice = voices[word.speaker]
        if turns and all(turns[-1][k] == v for k, v in voice.items()):
            turns[-1]["text"] += f" {word.text}"
        else:
            turns.append({**voice, "text": word.text})
    return turns


async def retranscribe(db: AsyncSession, conversation: Conversation, stt: STTService) -> bool:
    """The conversation's segments transcribed again as one recording; True when a
    segment's text changed. Its unknown voices are then told apart: by each word's
    speaker when the service gives it, else by the segments' fingerprints."""
    changed, told_apart = await _transcribe_again(db, conversation, stt)
    if not told_apart:
        await number_unknown_voices(db, conversation.id)
    return changed


async def _transcribe_again(db, conversation, stt) -> tuple[bool, bool]:
    """(a text changed, the voices were told apart by speaker). A conversation of one
    short segment, or whose audio is gone, stays as it is."""
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
    if not segments or (len(segments) == 1 and segments[0].duration_ms < LONE_SEGMENT_MS):
        return False, False

    pcm, spans = _joined([decode_segment(Path(s.audio_path).read_bytes()) for s in segments])
    stt_context = await build_stt_context(db, conversation.user_id)
    language, others = await account_languages(db, conversation.user_id)
    result = await stt.transcribe(
        pcm_to_wav(pcm),
        language=language,
        also=others or None,
        prompt=stt_context.prompt or None,
        keyterms=stt_context.keyterms,
        diarize=True,
    )
    if not result.words:
        return False, False  # a service without word times (OpenAI): the segments stay

    parts = assign_words(result.words, spans)
    changed = False
    for segment, part in zip(segments, parts):
        text = clean_transcription(" ".join(w.text for w in part))
        if not text:
            continue  # nothing heard here this time: what was heard before stays
        new = f"{speaker_prefix(segment.speaker)}{text}"
        if new != segment.transcription.text:
            segment.transcription.text = new
            segment.transcription.language = result.language
            changed = True

    if any(w.speaker is None for w in result.words):
        return changed, False
    voices = await _voices(db, conversation, segments, parts, pcm)
    for segment, part in zip(segments, parts):
        turns = [t for t in _turns(part, voices) if clean_transcription(t["text"])]
        if len(turns) >= 2:
            for turn in turns:
                turn["text"] = clean_transcription(turn["text"])
            segment.transcription.turns = turns
            continue
        segment.transcription.turns = None
        if turns and segment.speaker == "other" and segment.voice_profile_id is None:
            segment.voice_group = turns[0]["group"]  # numbered as in the turns
    return changed, True


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
