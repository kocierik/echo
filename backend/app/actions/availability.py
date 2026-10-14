"""Fixed answers when a tool request cannot reach the app it names.

Used by chat (requests that match the tool hint) and voice (every confirmed request)
before the intent check: a request about Gmail must not be answered from memory as if
Echo had looked, when Composio is down or Gmail is not connected. A word like "agenda"
alone does not make a request about the app: one LLM check decides whether the request
needs the app now; if not, it is answered from memory as usual.
"""

import logging
import re

from app.services.language import detect_language
from app.services.llm_base import LLMMessage

logger = logging.getLogger(__name__)

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
    missing = _missing(request, connected)
    if not missing:
        return None
    return TEXTS[detect_language(request)]["not_connected"].format(app=APP_NAMES[missing[0]])


def _missing(request: str, connected: list[str]) -> list[str]:
    return [slug for slug in named_toolkits(request) if slug not in set(connected)]


NEEDS_APP_PROMPT = """You route requests for a personal assistant called Echo. Echo can \
answer from its memory of the user's recorded conversations, or read and act on the \
user's apps. Decide whether this request needs Echo to read or change something in \
{apps} right now (list, search, create, send, update or delete there), or whether it \
asks about what was said, decided or planned in the user's conversations and can be \
answered from memory. Use the recent conversation for follow-ups.
Respond with ONLY a JSON object: {{"needs_app": true}} or {{"needs_app": false}}."""


async def needs_app(llm, request: str, history: list[dict], apps: str) -> bool:
    """One LLM check: does the request need to read or act on `apps` now? Errors -> False."""
    try:
        messages = [LLMMessage(role="system", content=NEEDS_APP_PROMPT.format(apps=apps))]
        for msg in history[-6:]:
            messages.append(LLMMessage(role=msg["role"], content=msg["content"]))
        messages.append(LLMMessage(role="user", content=request))
        result = await llm.complete_json(messages, temperature=0.0)
        return isinstance(result, dict) and result.get("needs_app") is True
    except Exception:
        logger.warning("App intent check failed; answering from memory", exc_info=True)
        return False


async def availability_notice(
    llm, request: str, history: list[dict], connected: list[str] | None
) -> str | None:
    """The fixed answer for a request that needs an app Echo cannot use, or None.

    `connected` None means the provider could not be reached. The answer is given only
    when the LLM check says the request needs the app (or, unreachable, any app) now;
    otherwise None and the caller answers as usual (from memory when nothing is usable).
    """
    if connected is None:
        named = named_toolkits(request)
        apps = (
            " or ".join(APP_NAMES[s] for s in named)
            if named
            else f"one of the user's connected apps ({', '.join(APP_NAMES.values())}, ...)"
        )
        if await needs_app(llm, request, history, apps):
            return unreachable_answer(request)
        return None
    missing = _missing(request, connected)
    if not missing:
        return None
    if not await needs_app(llm, request, history, " or ".join(APP_NAMES[s] for s in missing)):
        return None
    return not_connected_answer(request, connected)
