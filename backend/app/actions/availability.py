"""Fixed answers when a tool request cannot reach the app it names.

Used by chat (requests that match the tool hint) and voice (every confirmed request)
before the intent check: a request about Gmail must not be answered from memory as if
Echo had looked, when Composio is down or Gmail is not connected.
"""

import re

from app.services.language import detect_language

APP_NAMES = {
    "gmail": "Gmail",
    "googlecalendar": "Google Calendar",
    "slack": "Slack",
    "telegram": "Telegram",
    "todoist": "Todoist",
    "notion": "Notion",
}

# Words that name an initial toolkit (whole words, IT + EN).
_NAMED = (
    ("gmail", re.compile(r"\b(?:gmail|e-?mails?|mails?|posta)\b", re.IGNORECASE)),
    (
        "googlecalendar",
        re.compile(r"\b(?:calendars?|calendario|calendari|agenda|evento|eventi)\b", re.IGNORECASE),
    ),
    ("slack", re.compile(r"\bslack\b", re.IGNORECASE)),
    ("telegram", re.compile(r"\btelegram\b", re.IGNORECASE)),
    ("todoist", re.compile(r"\btodoist\b", re.IGNORECASE)),
    ("notion", re.compile(r"\bnotion\b", re.IGNORECASE)),
)

TEXTS = {
    "en": {
        "unreachable": "I couldn't reach your connected apps right now. Try again in a moment.",
        "not_connected": (
            "{app} isn't connected. Connect it in Settings → Automations → Integrations."
        ),
    },
    "it": {
        "unreachable": (
            "Non riesco a raggiungere le app collegate in questo momento. Riprova tra poco."
        ),
        "not_connected": (
            "{app} non è collegato. Collegalo da Impostazioni → Automazioni → Integrazioni."
        ),
    },
}


def named_toolkits(text: str) -> list[str]:
    """Initial toolkits the request names, in a fixed order."""
    return [slug for slug, pattern in _NAMED if pattern.search(text or "")]


def unreachable_answer(request: str) -> str:
    return TEXTS[detect_language(request)]["unreachable"]


def not_connected_answer(request: str, connected: list[str]) -> str | None:
    """The "{App} isn't connected" answer when the request names an app that is not
    connected; None otherwise."""
    missing = [slug for slug in named_toolkits(request) if slug not in set(connected)]
    if not missing:
        return None
    return TEXTS[detect_language(request)]["not_connected"].format(app=APP_NAMES[missing[0]])
