"""Tool tier classification used by the confirmation flow."""

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
