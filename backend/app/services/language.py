"""Cheap language detection for fixed replies (the app supports English and Italian).

LLM answers follow the question's language through the prompt; this is for
texts Echo writes itself (calendar confirmations, "nothing found" messages).
Unclear input defaults to English, the app language.
"""

import re

Language = str  # "en" | "it"

_ITALIAN = {
    "il", "lo", "la", "le", "gli", "un", "uno", "una", "di", "del", "della", "dei", "delle",
    "che", "cosa", "chi", "come", "quando", "dove", "quale", "quali", "perché",
    "mi", "ti", "ci", "ha", "ho", "hai", "abbiamo", "hanno", "è", "sono", "era",
    "con", "per", "non", "alle", "al", "allo", "nel", "nella", "sul", "sulla", "tra",
    "ieri", "oggi", "domani", "questa", "questo", "settimana", "prossima", "scorsa",
    "crea", "creare", "sposta", "cancella", "elimina", "aggiungi", "fissa", "impegni",
    "evento", "eventi", "appuntamento", "riunione", "detto", "parlato", "fatto",
}

_ENGLISH = {
    "the", "an", "of", "what", "who", "how", "when", "where", "which", "why",
    "me", "my", "you", "your", "did", "do", "does", "is", "are", "was", "were", "have", "has",
    "with", "for", "not", "to", "at", "on", "from", "about",
    "yesterday", "today", "tomorrow", "this", "next", "last", "week",
    "create", "move", "delete", "cancel", "add", "schedule", "event", "events",
    "meeting", "appointment", "tell", "told", "said", "talk", "talked",
}

_WORD = re.compile(r"[a-zàèéìòù']+")


def detect_language(text: str) -> Language:
    """Return "it" when the text is recognisably Italian, otherwise "en"."""
    words = _WORD.findall((text or "").lower())
    italian = sum(word in _ITALIAN for word in words)
    english = sum(word in _ENGLISH for word in words)
    return "it" if italian > english else "en"


# The languages Echo transcribes and takes dictation in
SUPPORTED_LANGUAGES = ("en", "it")


async def account_language(db, user_id) -> Language:
    """The language this account speaks; the server's default without an account row."""
    from sqlalchemy import select

    from app.core.config import settings
    from app.models.user import User

    language = await db.scalar(select(User.language).where(User.id == user_id))
    return language or settings.stt_language


def clear_language(text: str) -> Language | None:
    """The language when the words say it clearly; None when they do not ("ciao")."""
    words = _WORD.findall((text or "").lower())
    italian = sum(word in _ITALIAN for word in words)
    english = sum(word in _ENGLISH for word in words)
    if italian == english:
        return None
    return "it" if italian > english else "en"
