"""Tool tier classification used by the confirmation flow."""

import re
from enum import StrEnum


class ToolTier(StrEnum):
    READ = "read"
    CREATE = "create"
    CONFIRM = "confirm"


CONFIRM_KEYWORDS = frozenset({
    "SEND", "DELETE", "REMOVE", "UPDATE", "PATCH", "MOVE", "REPLY", "FORWARD",
    "POST", "TRASH", "ARCHIVE", "MODIFY", "COMPLETE", "CLOSE",
})
READ_KEYWORDS = frozenset({"LIST", "GET", "FETCH", "SEARCH", "FIND", "READ"})
CREATE_TOOLS = frozenset({
    "GMAIL_CREATE_EMAIL_DRAFT",
    "GOOGLECALENDAR_CREATE_EVENT",
    "GOOGLECALENDAR_QUICK_ADD",
    "TODOIST_CREATE_TASK",
    "NOTION_CREATE_NOTION_PAGE",
    "APPLEREMINDERS_CREATE_REMINDER",
    "APPLECALENDAR_CREATE_EVENT",
})


def classify_tool(slug: str) -> ToolTier:
    upper = slug.upper()
    tokens = set(upper.split("_"))
    if tokens & CONFIRM_KEYWORDS:
        return ToolTier.CONFIRM
    if upper in CREATE_TOOLS:
        return ToolTier.CREATE
    if tokens & READ_KEYWORDS:
        return ToolTier.READ
    return ToolTier.CONFIRM


def toolkit_of(slug: str) -> str:
    return slug.split("_", 1)[0].lower()


# Argument keys that mean a create also notifies or involves other people (an invite,
# a recipient, an assignee): the call then needs the user's confirmation.
_PEOPLE_KEY_PARTS = ("attendee", "recipient", "assignee", "responsible", "invite", "guest")
_PEOPLE_KEY_TOKENS = frozenset({"cc", "bcc"})


def is_people_key(key: str) -> bool:
    lowered = key.lower()
    if lowered == "send_updates" or lowered == "to" or lowered.startswith("to_"):
        return True
    if any(part in lowered for part in _PEOPLE_KEY_PARTS):
        return True
    # "cc"/"bcc" as whole words ("cc", "extra_cc", "bcc_list"), not inside "account"
    return bool(_PEOPLE_KEY_TOKENS & set(re.split(r"[^a-z0-9]+", lowered)))


def _non_empty(value) -> bool:
    if value is None or value is False:
        return False
    if isinstance(value, str | list | tuple | dict | set):
        return len(value) > 0
    return True


def classify_call(slug: str, arguments: dict) -> ToolTier:
    """The tier of one call: a CREATE that invites or notifies people needs CONFIRM."""
    tier = classify_tool(slug)
    if tier != ToolTier.CREATE or not isinstance(arguments, dict):
        return tier
    for key, value in arguments.items():
        if is_people_key(str(key)) and _non_empty(value):
            return ToolTier.CONFIRM
    return tier
