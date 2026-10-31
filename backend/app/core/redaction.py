"""What of a tool call's arguments may be written down, and how.

Two rules, for two records:

- the audit log (`action_log`, actions/audit.py) keeps a short readable summary: keys
  whose name says they hold a message body show only their length, the other values
  their first 80 characters (`summarize_arguments`). The user reads it to understand an
  action they confirmed;
- run tracking (`agent_steps`, core/runs.py) is stricter (`redact_for_tracking`): every
  value becomes its type and length, so subjects, searches and recipients never reach it.
  Only identifiers (`*_id`, `*_ids`), booleans and small whole numbers are kept, because
  they link a step to other data and are not personal content.

This module imports nothing from the app: core/runs.py may use it without reaching the
actions, services, agents or workers packages (tests/test_core_imports.py).
"""

# Keys whose name contains one of these hold message bodies: never written to the audit log.
_REDACTED_KEY_PARTS = ("body", "text", "content", "message", "markdown", "html")
_VALUE_MAX = 80
_SUMMARY_MAX = 300

# Run tracking: an identifier is kept only when it looks like one (short, not an address)
_ID_SUFFIXES = ("_id", "_ids")
_ID_VALUE_MAX = 64
_ID_LIST_MAX = 20
_SMALL_NUMBER = 1_000_000  # up to six digits


def _is_redacted(key: str) -> bool:
    lowered = key.lower()
    if lowered.endswith(("_id", "_ids")):  # message_id, thread_id: identifiers, not bodies
        return False
    return any(part in lowered for part in _REDACTED_KEY_PARTS)


def summarize_arguments(arguments: dict) -> str:
    """Compact, body-free description of tool arguments for the audit log."""
    parts = []
    for key, value in arguments.items():
        text = str(value)
        if _is_redacted(str(key)):
            shown = f"({len(text)} chars)"
        else:
            shown = text[:_VALUE_MAX]
        parts.append(f"{key}={shown}")
    return ", ".join(parts)[:_SUMMARY_MAX]


def _is_plain_id(value) -> bool:
    """A short string that is not an e-mail address (a calendar id can be one)."""
    return isinstance(value, str) and len(value) <= _ID_VALUE_MAX and "@" not in value


def _kept_id(value) -> bool:
    if _is_plain_id(value):
        return True
    return (
        isinstance(value, list | tuple)
        and len(value) <= _ID_LIST_MAX
        and all(_is_plain_id(item) for item in value)
    )


def _shape(value) -> str:
    """The value's type and length, never the value: "str(42)", "list(2)", "float(-)"."""
    try:
        size = str(len(value))
    except TypeError:
        size = "-"
    return f"{type(value).__name__}({size})"


def redact_for_tracking(arguments) -> dict:
    """Tool arguments as run tracking stores them (`agent_steps.args_redacted`).

    {"subject": "Budget", "to": ["a@x.it", "b@x.it"], "limit": 5, "event_id": "abc"}
    becomes {"subject": "str(6)", "to": "list(2)", "limit": 5, "event_id": "abc"}.
    """
    if not isinstance(arguments, dict):
        return {}
    out = {}
    for raw_key, value in arguments.items():
        key = str(raw_key)
        if key.lower().endswith(_ID_SUFFIXES) and _kept_id(value):
            out[key] = list(value) if isinstance(value, tuple) else value
        elif isinstance(value, bool):
            out[key] = value
        elif isinstance(value, int) and abs(value) < _SMALL_NUMBER:
            out[key] = value
        else:
            out[key] = _shape(value)
    return out
