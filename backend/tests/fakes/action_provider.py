from app.actions.policy import toolkit_of
from app.actions.provider import (
    INITIAL_TOOLKITS,
    AccountNotConnectedError,
    Toolkit,
    ToolResult,
)


class FakeActionProvider:
    def __init__(
        self,
        connected: set[str] | None = None,
        tools: dict[str, dict] | None = None,
        results: dict[str, ToolResult | Exception] | None = None,
    ):
        self.connected = connected if connected is not None else set()
        self.tools = tools or {}
        self.results = results or {}
        self.executed: list[tuple[str, dict]] = []

    async def list_toolkits(self, user_id: str, query: str | None = None) -> list[Toolkit]:
        out = [Toolkit(s, s.title(), f"{s} toolkit", s in self.connected)
               for s in INITIAL_TOOLKITS]
        if query:
            out = [t for t in out if query.lower() in (t.slug + t.name + t.description).lower()]
        return out

    async def connect_link(self, user_id: str, toolkit: str, callback_url: str | None) -> str:
        return f"https://connect.test/{toolkit}"

    async def disconnect(self, user_id: str, toolkit: str) -> None:
        self.connected.discard(toolkit)

    async def tools_for(self, user_id: str, toolkits: list[str]) -> list[dict]:
        return [
            schema for slug, schema in self.tools.items()
            if toolkit_of(slug) in toolkits and toolkit_of(slug) in self.connected
        ]

    async def execute(self, user_id: str, tool: str, arguments: dict) -> ToolResult:
        toolkit = toolkit_of(tool)
        if toolkit not in self.connected:
            raise AccountNotConnectedError(toolkit)
        self.executed.append((tool, arguments))
        result = self.results.get(tool, ToolResult(ok=True, data={}))
        if isinstance(result, Exception):
            raise result
        return result
