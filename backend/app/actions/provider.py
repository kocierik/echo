"""Provider-agnostic interface for third-party actions (Composio implements it)."""

from dataclasses import dataclass
from typing import Protocol

INITIAL_TOOLKITS = ("gmail", "googlecalendar", "slack", "telegram", "todoist", "notion")


@dataclass(frozen=True)
class Toolkit:
    slug: str
    name: str
    description: str
    connected: bool


@dataclass(frozen=True)
class ToolResult:
    ok: bool
    data: dict | list | str | None = None
    error: str | None = None
    # The call may or may not have taken effect (it timed out after being sent).
    unknown: bool = False


class ActionProviderError(Exception):
    pass


class ActionOutcomeUnknown(ActionProviderError):  # noqa: N818
    """An execute call timed out: the action may or may not have happened."""


class AccountNotConnectedError(ActionProviderError):
    def __init__(self, toolkit: str):
        super().__init__(f"Account not connected for toolkit: {toolkit}")
        self.toolkit = toolkit


class ActionProvider(Protocol):
    async def list_toolkits(self, user_id: str, query: str | None = None) -> list[Toolkit]: ...

    async def connected_toolkits(self, user_id: str) -> list[str]:
        """Slugs of every toolkit with an active account (one provider call)."""
        ...

    async def connect_link(
        self, user_id: str, toolkit: str, callback_url: str | None
    ) -> str: ...

    async def disconnect(self, user_id: str, toolkit: str) -> None: ...

    async def tools_for(self, user_id: str, toolkits: list[str]) -> list[dict]:
        """OpenAI tool schemas; function.name is the tool slug."""
        ...

    async def execute(self, user_id: str, tool: str, arguments: dict) -> ToolResult: ...
