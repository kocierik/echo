"""Translating a conversation's transcript into the user's language (POST
/api/conversations/{id}/translate).

Only the lines transcribed in another language are translated, without their speaker
tag, with the LLM in batches; each translation is kept (transcription_translations), so a
line is translated once per language. Correcting a line drops its translations
(services/transcription_editor.py). An answer that cannot be read leaves its lines
untranslated: the original is always there.
"""

import json
import logging
import re
import uuid

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.segment import Segment
from app.models.transcription import Transcription
from app.models.transcription_translation import TranscriptionTranslation
from app.services.language import account_languages
from app.services.llm_base import LLMMessage, LLMService

logger = logging.getLogger(__name__)

LANGUAGE_NAMES = {
    "en": "English", "it": "Italian", "es": "Spanish", "fr": "French", "de": "German",
    "pt": "Portuguese",
}

# Lines per LLM call
BATCH = 40

_SPEAKER_TAG = re.compile(r"^\s*\[[^\]]{1,20}\]\s*")

PROMPT = (
    "Translate each line of the JSON object below into {language}. They are lines of a "
    "conversation transcribed from speech: keep names, numbers and the speaker's tone, "
    "add nothing and explain nothing. Reply with JSON only: the same keys, each with its "
    "translation."
)


async def translate_conversation(
    db: AsyncSession, user_id: uuid.UUID, conversation_id: uuid.UUID, llm: LLMService
) -> tuple[str, dict[str, str]]:
    """The user's language and, by segment id, the translation of each line of the
    conversation in another language."""
    target, _ = await account_languages(db, user_id)
    rows = (
        await db.execute(
            select(Transcription.id, Transcription.segment_id, Transcription.text)
            .join(Segment, Segment.id == Transcription.segment_id)
            .where(
                Segment.conversation_id == conversation_id,
                Segment.user_id == user_id,
                Transcription.language != target,
            )
            .order_by(Segment.recorded_at)
        )
    ).all()
    rows = [row for row in rows if _SPEAKER_TAG.sub("", row.text or "").strip()]
    if not rows:
        return target, {}

    kept = {
        transcription_id: text
        for transcription_id, text in (
            await db.execute(
                select(TranscriptionTranslation.transcription_id, TranscriptionTranslation.text)
                .where(
                    TranscriptionTranslation.transcription_id.in_([row.id for row in rows]),
                    TranscriptionTranslation.language == target,
                )
            )
        ).all()
    }
    missing = [row for row in rows if row.id not in kept]
    for start in range(0, len(missing), BATCH):
        batch = missing[start : start + BATCH]
        translated = await _translate(
            llm, [_SPEAKER_TAG.sub("", row.text).strip() for row in batch], target
        )
        for row, text in zip(batch, translated):
            if not text:
                continue
            kept[row.id] = text
            # Two taps at once translate twice: the first one kept wins
            await db.execute(
                insert(TranscriptionTranslation)
                .values(id=uuid.uuid4(), transcription_id=row.id, language=target, text=text)
                .on_conflict_do_nothing(constraint="uq_transcription_translations_language")
            )
    await db.commit()
    return target, {str(row.segment_id): kept[row.id] for row in rows if row.id in kept}


async def _translate(llm: LLMService, lines: list[str], target: str) -> list[str | None]:
    """Each line translated, or None where the answer has none."""
    asked = {str(index + 1): line for index, line in enumerate(lines)}
    try:
        response = await llm.complete(
            [
                LLMMessage(
                    role="system",
                    content=PROMPT.format(language=LANGUAGE_NAMES.get(target, target)),
                ),
                LLMMessage(role="user", content=json.dumps(asked, ensure_ascii=False)),
            ],
            temperature=0.1,
        )
        answer = _first_object(response.content or "")
    except Exception:
        logger.warning("[Translate] The model failed", exc_info=True)
        answer = None
    if answer is None:
        return [None] * len(lines)
    return [
        value.strip() if isinstance(value := answer.get(key), str) and value.strip() else None
        for key in asked
    ]


def _first_object(text: str) -> dict | None:
    decoder = json.JSONDecoder()
    for match in re.finditer(r"\{", text):
        try:
            value, _ = decoder.raw_decode(text, match.start())
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return None
