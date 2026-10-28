"""What a routine run asks the agent and how its answer is read (workers/routines.py).

An `always` routine asks its instruction as it is and reports the answer. The others ask
for a JSON result: whether there is something to say, and for `only_new` one item per
thing found, so the server can drop what this routine already reported. Pure: no
database, no model calls.
"""

import json
import re
from dataclasses import dataclass, field
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

MODES = ("always", "only_if", "only_new")

# How many already-reported items the request lists; the server filters all of them anyway
SEEN_IN_PROMPT = 50

# Query parameters that track a click rather than name the page (utm_source, gclid, ...)
_TRACKING = re.compile(
    r"^(utm|utm_.*|gclid|fbclid|msclkid|mc_cid|mc_eid|ref|refid|trk|trackingid)$", re.IGNORECASE
)

_COULD_NOT = (
    'If you could not check (no web search, an app failed), set "report" to true and say '
    "what you could not check."
)

_CONTRACT = (
    "Reply with JSON only, no other text: "
    '{"report": true or false, "intro": "...", "text": "...", '
    '"items": [{"title": "...", "line": "...", "url": "..."}]}. '
    "Write intro, text and items in the language of the request above, not in English "
    "unless it is in English."
)

_ONLY_IF = (
    "This runs on a schedule and must speak only when the condition in the request holds. "
    'Set "report" to true only when it holds, with "text" the message for the user; '
    'otherwise "report" false and "text" empty. Leave "items" empty. ' + _COULD_NOT
)

_ONLY_NEW = (
    "This runs on a schedule and must speak only about things that are new. "
    'Put one entry in "items" per thing found: its "title", a "line" of a few words '
    '(where, who, when) and its "url" when there is one. "intro" is one short line '
    'before the list. Set "report" to false when nothing new was found. ' + _COULD_NOT
)

CONVERT_PROMPT = (
    "Turn the assistant's answer below into JSON, without adding anything it does not say. "
    + _CONTRACT
    + ' "report" is true when the answer has something to tell the user; '
    'for a list of things found, one entry in "items" each. When it says it could not check '
    'or something failed, "report" is true.'
)


@dataclass(frozen=True)
class RoutineResult:
    """A run's structured answer: whether to report, and what."""

    report: bool
    intro: str = ""
    text: str = ""
    # {"key", "title", "line", "url"}
    items: list[dict] = field(default_factory=list)


def framed_request(instruction: str, mode: str, seen: list[dict]) -> str:
    """The request the agent gets for a run of this routine."""
    if mode == "only_if":
        return f"{instruction}\n\n{_ONLY_IF} {_CONTRACT}"
    if mode == "only_new":
        request = f"{instruction}\n\n{_ONLY_NEW} {_CONTRACT}"
        if seen:
            lines = "\n".join(
                f"- {item.get('title', '')}" + (f" {item['url']}" if item.get("url") else "")
                for item in seen[:SEEN_IN_PROMPT]
            )
            request += f"\n\nAlready reported, leave these out:\n{lines}"
        return request
    return instruction


def parse_result(answer: str, mode: str) -> RoutineResult | None:
    """The first JSON object in the answer (bare, fenced or with text around it), or None
    when there is none or its "report" is not true or false."""
    data = _first_object(answer)
    if data is None or not isinstance(data.get("report"), bool):
        return None
    items = []
    for raw in data.get("items") or []:
        if not isinstance(raw, dict):
            continue
        title = _text(raw.get("title"))
        if not title:
            continue
        item = {
            "title": title,
            "line": _text(raw.get("line")),
            "url": _text(raw.get("url")) or None,
        }
        items.append({"key": item_key(item), **item})
    return RoutineResult(
        report=data["report"],
        intro=_text(data.get("intro")),
        text=_text(data.get("text")),
        items=items,
    )


def item_key(item: dict) -> str:
    """Stable across runs: the link as https, host lowercased without "www.", no trailing
    slash or fragment, and its query sorted without tracking parameters (the query that
    names the item, Indeed's `jk=`, stays); else the title lowercased with no punctuation."""
    url = (item.get("url") or "").strip()
    if url:
        if "://" not in url:
            url = f"https://{url}"
        parts = urlsplit(url)
        if parts.netloc:
            host = parts.netloc.lower().removeprefix("www.")
            query = urlencode(sorted(
                (name, value)
                for name, value in parse_qsl(parts.query, keep_blank_values=True)
                if not _TRACKING.match(name)
            ))
            return urlunsplit(("https", host, parts.path.rstrip("/"), query, ""))
    title = re.sub(r"[^\w\s]", " ", (item.get("title") or "").lower())
    return " ".join(title.split())


def fresh_items(items: list[dict], seen_keys: set[str]) -> list[dict]:
    """The items not reported before, in order, each once."""
    kept, keys = [], set(seen_keys)
    for item in items:
        if item["key"] in keys:
            continue
        keys.add(item["key"])
        kept.append(item)
    return kept


def compose_text(intro: str, items: list[dict]) -> str:
    """The intro, then one line per item: "• title — line url"."""
    lines = [intro] if intro else []
    for item in items:
        line = f"• {item['title']}"
        if item.get("line"):
            line += f" — {item['line']}"
        if item.get("url"):
            line += f" {item['url']}"
        lines.append(line)
    return "\n".join(lines)


def _first_object(answer: str) -> dict | None:
    decoder = json.JSONDecoder()
    for match in re.finditer(r"\{", answer):
        try:
            value, _ = decoder.raw_decode(answer, match.start())
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return None


def _text(value) -> str:
    return value.strip() if isinstance(value, str) else ""
