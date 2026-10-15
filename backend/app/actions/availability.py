"""One intent check routes a possible app request: memory, a fixed answer, or the agent.

Used by chat (requests that match the tool hint) and voice (every confirmed request).
A single LLM call says whether the request needs apps right now and which ones; from
that one answer the request is answered from memory, gets a fixed answer (the app it
needs is not connected, or the connected apps could not be reached), or goes to the
action agent. A request for an app that is not connected is never routed to another app,
and a word like "agenda" alone does not make a request about the calendar.
"""

import logging
import re
from dataclasses import dataclass, field

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

TEXTS = {
    "en": {
        "unreachable": "I couldn't reach your connected apps right now. Try again in a moment.",
        "not_connected": (
            "{app} isn't connected. Connect it in Settings → Automations → Integrations."
        ),
        "none_connected": (
            "No apps are connected yet. Connect one in Settings → Automations → Integrations."
        ),
    },
    "it": {
        "unreachable": (
            "Non riesco a raggiungere le app collegate in questo momento. Riprova tra poco."
        ),
        "not_connected": (
            "{app} non è collegato. Collegalo da Impostazioni → Automazioni → Integrazioni."
        ),
        "none_connected": (
            "Nessuna app è ancora collegata. Collegane una in Impostazioni → Automazioni → "
            "Integrazioni."
        ),
    },
}

HISTORY_MESSAGES = 6

INTENT_PROMPT = """You route requests for a personal assistant called Echo. Echo can \
answer from its memory of the user's recorded conversations, or read and act on the \
user's apps (list, search, create, send, update or delete something there).
{apps}
Decide whether this request needs Echo to read or change something in an app right now, \
and which apps (by slug, from the lists above). A request about what was said, decided \
or planned in the user's past conversations is answered from memory and needs no app, \
even when it mentions an agenda, a meeting, an email or a task. A request for an app \
that is NOT connected still needs that app: name it, and Echo will ask the user to \
connect it. Use the recent conversation for follow-ups.{camera}
Respond with ONLY a JSON object: {{{camera_key}"needs_apps": true, "apps": ["<slug>", ...]}} \
or {{{camera_key}"needs_apps": false, "apps": []}}."""

CAMERA_SECTION = """
Echo also has a camera on the user's wearable. A request to take a photo, or a question \
about what the user is looking at right now ("what is this?", "read this", "how much is \
this?"), needs the camera: set "camera" to true. A question about the past never needs \
it."""


@dataclass
class RequestIntent:
    needs_apps: bool = False
    apps: list[str] = field(default_factory=list)
    # The wearable camera: take a photo now (voice requests only)
    camera: bool = False
    # Names the model gave that match no known or connected app, as written
    unresolved: list[str] = field(default_factory=list)


@dataclass
class Route:
    """`kind`: "memory", "notice" (answer with `notice`), "agent", or "photo" (camera)."""

    kind: str
    notice: str | None = None
    # For "agent": the connected apps the request names (empty: any connected app).
    # Only their tools are offered, which keeps the agent's prompt small and fast.
    apps: list[str] = field(default_factory=list)


def _label(slug: str, known_apps: dict[str, str]) -> str:
    return f"{slug} ({known_apps[slug]})" if slug in known_apps else slug


def _apps_section(connected: list[str] | None, known_apps: dict[str, str]) -> str:
    if connected is None:
        listed = ", ".join(_label(s, known_apps) for s in known_apps)
        return (
            "Which apps are connected could not be checked right now. Apps Echo can "
            f"use: {listed}."
        )
    connected_text = ", ".join(_label(s, known_apps) for s in connected) or "none"
    missing = [s for s in known_apps if s not in connected]
    missing_text = ", ".join(_label(s, known_apps) for s in missing) or "none"
    return (
        f"Connected apps: {connected_text}.\n"
        f"Apps Echo supports that are NOT connected: {missing_text}."
    )


def _normalize(name: str) -> str:
    """"Google Calendar", "google_calendar", "GOOGLECALENDAR" -> "googlecalendar"."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def _partial_match(name: str, lookup: dict[str, str]) -> str | None:
    """"calendar" -> "googlecalendar" when exactly one app contains it (3+ chars)."""
    if len(name) < 3:
        return None
    matches = {slug for key, slug in lookup.items() if name in key}
    return matches.pop() if len(matches) == 1 else None


def _parse_intent(
    result, connected: list[str] | None, known_apps: dict[str, str]
) -> RequestIntent:
    if not isinstance(result, dict):
        return RequestIntent()
    if result.get("camera") is True:
        return RequestIntent(camera=True)
    needs, apps = result.get("needs_apps"), result.get("apps", [])
    if needs is not True or not isinstance(apps, list):
        return RequestIntent()
    # Slugs and display names, in any spelling, resolve to the slug
    lookup = {_normalize(slug): slug for slug in (*known_apps, *(connected or []))}
    lookup.update({_normalize(name): slug for slug, name in known_apps.items()})
    slugs: list[str] = []
    unresolved: list[str] = []
    for app in apps:
        if not isinstance(app, str) or not _normalize(app):
            continue
        slug = lookup.get(_normalize(app)) or _partial_match(_normalize(app), lookup)
        if slug is None:
            if app.strip() not in unresolved:
                unresolved.append(app.strip())
        elif slug not in slugs:
            slugs.append(slug)
    return RequestIntent(needs_apps=True, apps=slugs, unresolved=unresolved)


async def classify_request(
    llm,
    question: str,
    history: list[dict],
    connected: list[str] | None,
    known_apps: dict[str, str],
    camera: bool = False,
) -> RequestIntent:
    """One LLM call: does the request need apps (or, with `camera`, a photo) now, and
    which? Errors -> memory.

    `connected` None means the connected list could not be fetched; the prompt then
    lists every known app.
    """
    try:
        prompt = INTENT_PROMPT.format(
            apps=_apps_section(connected, known_apps),
            camera=CAMERA_SECTION if camera else "",
            camera_key='"camera": false, ' if camera else "",
        )
        messages = [LLMMessage(role="system", content=prompt)]
        for msg in history[-HISTORY_MESSAGES:]:
            messages.append(LLMMessage(role=msg["role"], content=msg["content"]))
        messages.append(LLMMessage(role="user", content=question))
        result = await llm.complete_json(messages, temperature=0.0)
    except Exception:
        logger.warning("Request intent check failed; answering from memory", exc_info=True)
        return RequestIntent()
    return _parse_intent(result, connected, known_apps)


def unreachable_answer(request: str) -> str:
    return TEXTS[detect_language(request)]["unreachable"]


def not_connected_answer(request: str, slug: str) -> str:
    """`slug` is a known slug or, for an app Echo cannot resolve, the name as given."""
    app = APP_NAMES.get(slug) or (slug if slug != slug.lower() else slug.title())
    return TEXTS[detect_language(request)]["not_connected"].format(app=app)


def none_connected_answer(request: str) -> str:
    return TEXTS[detect_language(request)]["none_connected"]


async def route_request(
    llm,
    request: str,
    history: list[dict],
    connected: list[str] | None,
    camera: bool = False,
) -> Route:
    """Where a possible app request goes, from one intent check.

    `connected` None means Composio is configured but the connected list could not be
    fetched. Not needed -> memory; unreachable and needed -> the "couldn't reach" text;
    a needed app that is not connected, or that matches no app Echo knows ->
    "{App} isn't connected" (never another app); needed with no app named and nothing
    connected -> "No apps are connected yet"; otherwise the agent. With `camera` (voice
    requests), a request to take a photo or about what the user is looking at -> photo.
    """
    intent = await classify_request(llm, request, history, connected, APP_NAMES, camera)
    if camera and intent.camera:
        return Route("photo")
    if not intent.needs_apps:
        return Route("memory")
    if connected is None:
        return Route("notice", unreachable_answer(request))
    missing = [slug for slug in intent.apps if slug not in connected]
    if missing:
        return Route("notice", not_connected_answer(request, missing[0]))
    if intent.unresolved:
        return Route("notice", not_connected_answer(request, intent.unresolved[0]))
    if not connected:
        return Route("notice", none_connected_answer(request))
    return Route("agent", apps=list(intent.apps))
