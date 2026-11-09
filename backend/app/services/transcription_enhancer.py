"""Transcription enhancement: context-aware STT prompting and post-processing.

Improves transcription quality by:
1. Building a Whisper prompt from known entities (names, jargon)
2. Filtering out trivially short/empty transcriptions
3. Basic text cleanup (whitespace normalization)
"""

import logging
import re
import uuid
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

# Minimum meaningful transcription length (characters)
MIN_TRANSCRIPTION_LENGTH = 2


@dataclass(frozen=True)
class STTContext:
    """What the speech-to-text service is told about the user's vocabulary."""

    # A realistic "previous transcription" for prompt-conditioned models (OpenAI)
    prompt: str
    # Short names and terms for providers that take a list (Deepgram keyterms)
    keyterms: list[str]


# A keyterm is a name, not a sentence: longer entity names (most tasks) are skipped
_MAX_KEYTERM_WORDS = 3
_MAX_KEYTERM_CHARS = 40


async def build_stt_context(db: "AsyncSession", user_id: uuid.UUID) -> STTContext:
    """Build the transcription hints from the user's known entities.

    Names are the highest-value hint (especially non-English ones), then project names
    and recurring topics.
    """
    from sqlalchemy import select

    from app.models.entity import Entity

    people_names = list(
        (
            await db.execute(
                select(Entity.name)
                .where(Entity.user_id == user_id)
                .where(Entity.entity_type == "person")
                .order_by(Entity.updated_at.desc())
                .limit(20)
            )
        ).scalars()
    )
    topic_names = list(
        (
            await db.execute(
                select(Entity.name)
                .where(Entity.user_id == user_id)
                .where(Entity.entity_type != "person")
                .order_by(Entity.updated_at.desc())
                .limit(10)
            )
        ).scalars()
    )
    places = await place_terms(db, user_id)
    learned = await corrected_terms(db, user_id)
    return STTContext(
        prompt=_prompt(people_names, topic_names),
        # Places before topics: a city said once is a request ("che tempo fa a Nizza")
        keyterms=_keyterms([ASSISTANT_NAME, *people_names, *learned, *places, *topic_names]),
    )


# The words the user put into transcripts by hand: what the service keeps mishearing
MAX_LEARNED = 15
_LEARNED_FROM_EDITS = 200
_WORD = re.compile(r"[^\W\d_][\w'’-]*")


def learned_words(edits: list[tuple[str, str]]) -> list[str]:
    """The words a correction added (in the new text, not in the old), the most often
    corrected first: once per correction, at least 3 letters."""
    counts: dict[str, int] = {}
    spelling: dict[str, str] = {}
    for old, new in edits:
        before = {w.casefold() for w in _WORD.findall(old or "")}
        added = {w.casefold(): w for w in _WORD.findall(new or "") if len(w) >= 3}
        for key, word in added.items():
            if key not in before:
                counts[key] = counts.get(key, 0) + 1
                spelling.setdefault(key, word)
    ranked = sorted(counts, key=lambda k: -counts[k])
    return [spelling[k] for k in ranked[:MAX_LEARNED]]


async def corrected_terms(db: "AsyncSession", user_id: uuid.UUID) -> list[str]:
    """The words learned from the user's latest transcript corrections."""
    from sqlalchemy import select

    from app.models.transcription_edit import TranscriptionEdit

    rows = (
        await db.execute(
            select(TranscriptionEdit.old_text, TranscriptionEdit.new_text)
            .where(TranscriptionEdit.user_id == user_id)
            .order_by(TranscriptionEdit.created_at.desc())
            .limit(_LEARNED_FROM_EDITS)
        )
    ).all()
    return learned_words([tuple(row) for row in rows])


# The Italian names of cities the phone's addresses give in their own language: an
# Italian says "Nizza", the address says "Nice", and without the hint "a Nizza" is heard
# as "Anit"
ITALIAN_NAMES = {
    "nice": "Nizza", "menton": "Mentone", "monaco": "Monaco", "paris": "Parigi",
    "london": "Londra", "marseille": "Marsiglia", "lyon": "Lione", "geneva": "Ginevra",
    "genève": "Ginevra", "zurich": "Zurigo", "zürich": "Zurigo", "munich": "Monaco di Baviera",
    "münchen": "Monaco di Baviera", "barcelona": "Barcellona", "lisbon": "Lisbona",
    "lisboa": "Lisbona", "brussels": "Bruxelles", "berlin": "Berlino", "wien": "Vienna",
    "prague": "Praga", "praha": "Praga", "antibes": "Antibes", "cannes": "Cannes",
}
MAX_PLACES = 10


async def place_terms(db: "AsyncSession", user_id: uuid.UUID) -> list[str]:
    """The cities of the places the user stayed at (the last part of their addresses),
    each also by its Italian name: the most visited first."""
    from sqlalchemy import func, select

    from app.models.place_visit import PlaceVisit

    try:
        rows = (
            await db.execute(
                select(PlaceVisit.address, func.count())
                .where(PlaceVisit.user_id == user_id, PlaceVisit.address.isnot(None))
                .group_by(PlaceVisit.address)
                .order_by(func.count().desc())
                .limit(200)
            )
        ).all()
    except Exception:
        return []
    counts: dict[str, int] = {}
    for address, count in rows:
        city = " ".join(str(address).rsplit(",", 1)[-1].split())
        # "06000 Nice" in some formats: the name without the postcode
        city = " ".join(word for word in city.split() if not word.isdigit())
        if city:
            counts[city] = counts.get(city, 0) + count
    terms: list[str] = []
    for city in sorted(counts, key=counts.get, reverse=True)[:MAX_PLACES]:
        italian = ITALIAN_NAMES.get(city.lower())
        terms += [italian, city] if italian and italian.lower() != city.lower() else [city]
    return terms


# The name the user calls the assistant by: said by an Italian it comes out as "ecco"
# unless the model expects it (voice requests: actions/voice.py)
ASSISTANT_NAME = "Echo"


def _prompt(people_names: list[str], topic_names: list[str]) -> str:
    """A realistic utterance: Whisper-style models treat it as context, not instructions."""
    parts = [f"Ehi {ASSISTANT_NAME}, ricordamelo."]
    if people_names:
        parts.append(f"Ho parlato con {', '.join(people_names[:10])}.")
    if topic_names:
        parts.append(f"Abbiamo discusso di {', '.join(topic_names[:5])}.")
    # The prompt budget is ~224 tokens: keep it short
    return " ".join(parts)[:500]


def _keyterms(names: list[str]) -> list[str]:
    terms: list[str] = []
    seen: set[str] = set()
    for name in names:
        term = " ".join(name.split())
        if (
            not term
            or len(term) > _MAX_KEYTERM_CHARS
            or len(term.split()) > _MAX_KEYTERM_WORDS
            or term.lower() in seen
        ):
            continue
        seen.add(term.lower())
        terms.append(term)
    return terms


def is_meaningful_transcription(text: str) -> bool:
    """Check if a transcription contains meaningful content worth analyzing.

    Filters out:
    - Very short texts (< 3 chars, likely noise/artifacts)
    - Only punctuation/whitespace

    Note: we intentionally keep filler words like "sì", "ok" because in context
    they signal agreement/confirmation which is valuable for understanding conversations.

    Returns True if the text should proceed to entity extraction.
    """
    text = text.strip()

    if len(text) < 2:
        return False

    # Check if there's at least one alphabetic character
    if not any(c.isalpha() for c in text):
        return False

    return True


def clean_transcription(text: str) -> str:
    """Basic post-processing of transcription text.

    - Normalize whitespace
    - Remove leading/trailing artifacts
    - Remove Whisper hallucination loops (repeated phrases)
    - Ensure first letter is capitalized
    """
    # Normalize whitespace
    text = re.sub(r"\s+", " ", text).strip()

    # Remove Whisper hallucination: same sentence repeated 3+ times
    # Matches patterns like "X. X. X." or "X, X, X"
    text = re.sub(r"(.{10,}?[.!?,])\s*(\1\s*){2,}", r"\1", text)

    # Also catch repetitions without trailing punctuation
    text = re.sub(r"(.{10,}?)\s+(\1\s*){2,}", r"\1", text)

    text = text.strip()

    # Capitalize first letter
    if text and text[0].islower():
        text = text[0].upper() + text[1:]

    return text


_SPEAKER_PREFIXES = {"self": "[You] ", "other": "[Others] "}


def speaker_prefix(speaker: str | None) -> str:
    """Tag prepended to a new transcription's text ("" when the speaker is unknown).

    Older transcriptions may still carry the Italian tags [Tu]/[Altri]; the
    mobile app strips both forms.
    """
    return _SPEAKER_PREFIXES.get(speaker or "", "")
