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
from dataclasses import replace
from datetime import datetime, timedelta
from pathlib import Path

from sqlalchemy import func, or_, select
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
from app.services.voice_embedding import embed_voice, loudest_frames, normalize
from app.services.voice_profiles import (
    label_speaker,
    list_profiles,
    number_unknown_voices,
    voice_context,
    voice_similarity,
    voice_thresholds,
)

logger = logging.getLogger(__name__)

# Between two segments in the joined recording: a pause, so words do not run together
GAP_SECONDS = 0.5
# A conversation of one segment shorter than this is left as it is: one voice, most likely
LONE_SEGMENT_MS = 10_000
# Fewer windows than this (12 s of speech) are too few to tell two voices apart
SPLIT_MIN_WINDOWS = 3
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
    {speaker: {"speaker": "self"|"other", "profile_id": str|None, "group": int|None,
    "embedding": [...]|None}}. The fingerprint stays with the turns: the user can then
    say whose voice one turn is (voice_profiles.assign_voice)."""
    profiles = await list_profiles(db, conversation.user_id)
    has_self = any(p.is_self for p in profiles)
    # Compared with the pendant's own sound taken away (services/voice_profiles.py)
    center = (await voice_context(db, conversation.user_id)).center
    match_from, _, margin = voice_thresholds(center is not None)
    words = [w for part in parts for w in part]
    speakers = list(dict.fromkeys(w.speaker for w in words))  # in the order they spoke
    embeddings = {}
    for speaker in speakers:
        audio = b"".join(pcm[_at(w.start):_at(w.end)] for w in words if w.speaker == speaker)
        embeddings[speaker] = await embed_voice(pcm_to_wav(audio))
    # Through the pendant's microphone everyone sounds much alike (~0.8 to the user's
    # own voice): each profile goes to one voice only, the closest first
    pairs = sorted(
        (
            (voice_similarity(profile.embedding, embedding, center), index, profile)
            for index, embedding in enumerate(embeddings.values())
            if embedding is not None
            for profile in profiles
        ),
        key=lambda pair: -pair[0],
    )
    # A voice too close to two profiles is neither's (Omi's margin)
    ranked: dict = {}
    for similarity, index, _ in pairs:
        ranked.setdefault(index, []).append(similarity)
    ambiguous = {
        index for index, sims in ranked.items()
        if len(sims) > 1 and sims[0] - sims[1] < margin
    }
    matched: dict = {}
    for similarity, index, profile in pairs:
        if similarity < match_from:
            break
        if index not in ambiguous and index not in matched and profile not in matched.values():
            matched[index] = profile

    voices: dict = {}
    unknown: list = []
    for index, speaker in enumerate(speakers):
        profile = matched.get(index)
        embedding = embeddings[speaker]
        voice = {
            "speaker": "other", "profile_id": None, "group": None,
            "embedding": None if embedding is None else [round(float(x), 5) for x in embedding],
        }
        if profile is not None:
            voice["speaker"] = "self" if profile.is_self else "other"
            voice["profile_id"] = str(profile.id)
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


def _windows(words: list[Word], seconds: float) -> list[list[Word]]:
    """Words in a row, cut between words into windows of at least `seconds`; a shorter
    rest goes with the last window."""
    windows: list[list[Word]] = []
    current: list[Word] = []
    for word in words:
        current.append(word)
        if current[-1].end - current[0].start >= seconds:
            windows.append(current)
            current = []
    if current:
        if windows:
            windows[-1].extend(current)
        else:
            windows.append(current)
    return windows


def _mean(vectors: list[list[float]]) -> list[float]:
    return normalize([sum(column) for column in zip(*vectors)])


def most_different_split(vectors: list[list[float]]) -> tuple[float, list[int]]:
    """Of every way to put the windows in two groups, the one whose two average voices
    are least alike: (their cosine, the group, 0 or 1, of each window). Few windows (a
    segment is at most ~25 s): every way is tried."""
    best, groups = 2.0, [0] * len(vectors)
    for mask in range(1, 2 ** (len(vectors) - 1)):
        labels = [(mask >> i) & 1 for i in range(len(vectors))]
        first = [v for v, label in zip(vectors, labels) if label == 0]
        second = [v for v, label in zip(vectors, labels) if label == 1]
        similarity = sum(a * b for a, b in zip(_mean(first), _mean(second)))
        if similarity < best:
            best, groups = similarity, labels
    return best, groups


async def split_by_voice(words: list[Word], pcm: bytes, center) -> list[Word] | None:
    """The words of a segment the speech-to-text heard as one voice, with speaker 0 or
    1 when its windows' fingerprints fall into two clearly different voices; else None.
    The speech-to-text separates voices only now and then (93 of 1252 segments): through
    the pendant's one microphone they sound alike to it."""
    windows = _windows(words, settings.voice_split_window_seconds)
    if len(windows) < SPLIT_MIN_WINDOWS:
        return None
    vectors: dict[int, list[float]] = {}
    for index, window in enumerate(windows):
        audio = loudest_frames(pcm[_at(window[0].start):_at(window[-1].end)])
        embedding = await embed_voice(pcm_to_wav(audio))
        if embedding is None:
            continue  # too little speech in it: it goes with the window before
        if center is not None:
            embedding = normalize([float(e) - c for e, c in zip(embedding, center)])
        vectors[index] = embedding
    if len(vectors) < SPLIT_MIN_WINDOWS:
        return None
    similarity, groups = most_different_split(list(vectors.values()))
    if similarity >= settings.voice_split_below:
        return None
    group_of = dict(zip(vectors, groups))
    split: list[Word] = []
    group = group_of[min(group_of)]
    for index, window in enumerate(windows):
        group = group_of.get(index, group)
        split += [replace(word, speaker=group) for word in window]
    return split


async def segment_turns(db: AsyncSession, segment: Segment, words: list[Word], pcm: bytes):
    """A segment where several spoke, split into its turns: each voice recognised from
    what it said in this segment. None with one voice. The speech-to-text tells the
    voices apart; when it heard one, the fingerprints may still find two (`split_by_voice`).

    Unknown voices are told apart but not numbered: "Person 2" is the same person only
    across a whole conversation, which is read again when it closes (`retranscribe`).
    """
    if any(w.speaker is None for w in words) or len({w.speaker for w in words}) < 2:
        center = (await voice_context(db, segment.user_id)).center
        words = await split_by_voice(words, pcm, center)
        if words is None:
            return None
    voices = await _voices(db, segment, [segment], [words], pcm)
    turns = [t for t in _turns(words, voices) if clean_transcription(t["text"])]
    if len(turns) < 2:
        return None
    for turn in turns:
        turn["text"] = clean_transcription(turn["text"])
        turn["group"] = None
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
        # One voice to the speech-to-text: the fingerprints may still hear two
        by_voice = await segment_turns(db, segment, part, pcm) if turns else None
        if by_voice:
            segment.transcription.turns = by_voice
            continue
        segment.transcription.turns = None
        if not turns or segment.voice_match == "confirmed":
            continue  # the user said who it is
        # One voice: recognised from all it said, surer than from this segment alone
        voice = turns[0]
        segment.voice_profile_id = uuid.UUID(voice["profile_id"]) if voice["profile_id"] else None
        segment.voice_match = "auto" if voice["profile_id"] else None
        segment.voice_group = voice["group"]
        if segment.speaker != voice["speaker"]:
            label_speaker(segment, voice["speaker"])
            changed = True
    return changed, True


def closed_before(now: datetime) -> datetime:
    """A conversation quiet since before this is closed (as for its summary)."""
    return now - timedelta(milliseconds=settings.silence_timeout_ms)


async def conversations_to_retranscribe(db: AsyncSession, now: datetime, limit: int):
    """Closed, analysed, not yet read whole; the oldest first. Not while its speech is
    still arriving (the card's backlog comes late, a segment at a time) or waiting to be
    transcribed: it would be read with half of it missing."""
    arriving = (
        select(Segment.id)
        .where(Segment.conversation_id == Conversation.id)
        .where(or_(
            Segment.received_at >= closed_before(now),
            Segment.transcription_status.in_(("pending", "processing")),
        ))
        .exists()
    )
    return list(await db.scalars(
        select(Conversation)
        .where(Conversation.retranscribed_at.is_(None))
        .where(Conversation.analysis_status == "completed")
        .where(func.coalesce(Conversation.ended_at, Conversation.started_at) < closed_before(now))
        .where(~arriving)
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
