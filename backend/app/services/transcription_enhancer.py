"""Transcription enhancement: context-aware STT prompting and post-processing.

Improves transcription quality by:
1. Building a Whisper prompt from known entities (names, jargon)
2. Filtering out trivially short/empty transcriptions
3. Basic text cleanup (whitespace normalization)
"""

import logging
import re
import uuid
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

# Minimum meaningful transcription length (characters)
MIN_TRANSCRIPTION_LENGTH = 5

# Filler patterns that don't add information
FILLER_PATTERNS = re.compile(
    r"^(\s*(sì|si|ok|no|eh|ah|mh|uhm|hmm|okay|allora|ecco|boh|ciao|\.+)\s*)+$",
    re.IGNORECASE,
)


async def build_stt_prompt(db: "AsyncSession", user_id: uuid.UUID) -> str:
    """Build a Whisper conditioning prompt from the user's known entities.

    Whisper uses the prompt to bias transcription toward known vocabulary.
    This dramatically improves accuracy for:
    - People's names (especially non-English names)
    - Technical jargon or project names
    - Recurring topics

    The prompt is structured as a realistic "previous transcription" so Whisper
    treats it as context rather than instructions.
    """
    from sqlalchemy import select

    from app.models.entity import Entity

    # Fetch recent person entities (names are the highest-value prompt content)
    people_query = (
        select(Entity.name)
        .where(Entity.user_id == user_id)
        .where(Entity.entity_type == "person")
        .order_by(Entity.updated_at.desc())
        .limit(20)
    )
    result = await db.execute(people_query)
    people_names = [row[0] for row in result.all()]

    # Fetch recent non-person entities for jargon/topics
    topics_query = (
        select(Entity.name)
        .where(Entity.user_id == user_id)
        .where(Entity.entity_type != "person")
        .order_by(Entity.updated_at.desc())
        .limit(10)
    )
    result = await db.execute(topics_query)
    topic_names = [row[0] for row in result.all()]

    if not people_names and not topic_names:
        return ""

    # Build prompt as a realistic utterance (Whisper works best this way)
    parts = []
    if people_names:
        # Include names naturally so Whisper learns the vocabulary
        names_str = ", ".join(people_names[:10])
        parts.append(f"Ho parlato con {names_str}.")

    if topic_names:
        topics_str = ", ".join(topic_names[:5])
        parts.append(f"Abbiamo discusso di {topics_str}.")

    prompt = " ".join(parts)

    # Whisper prompt max is ~224 tokens, keep it short
    if len(prompt) > 500:
        prompt = prompt[:500]

    return prompt


def is_meaningful_transcription(text: str) -> bool:
    """Check if a transcription contains meaningful content worth analyzing.

    Filters out:
    - Very short texts (< 5 chars)
    - Pure filler words ("sì", "ok", "eh", etc.)
    - Only punctuation/whitespace

    Returns True if the text should proceed to entity extraction.
    """
    text = text.strip()

    if len(text) < MIN_TRANSCRIPTION_LENGTH:
        return False

    if FILLER_PATTERNS.match(text):
        return False

    # Check if there's at least one word with > 2 characters
    words = [w for w in text.split() if len(w) > 2 and w.isalpha()]
    if len(words) < 2:
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
