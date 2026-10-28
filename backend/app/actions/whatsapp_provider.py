"""The user's WhatsApp as an app the action agent reads, through the bridge
(services/whatsapp_bridge.py): recent private chats and a chat's messages, from the
bridge's memory (7 days at most). Read-only: nothing is ever sent.

`with_whatsapp` adds it to any provider (Composio, the phone's apps, none) only while
the user's WhatsApp is linked, asked of the bridge once a minute: otherwise, or on a
server without a bridge, the provider is returned as it is.
"""

import logging
import uuid

from app.actions.policy import toolkit_of
from app.actions.provider import AccountNotConnectedError, ToolResult
from app.services import whatsapp_bridge
from app.services.whatsapp_bridge import BridgeError

logger = logging.getLogger(__name__)

WHATSAPP_NAMES = {"whatsapp": "WhatsApp"}
LINKED_KEY = "whatsapp:linked:{user_id}"
LINKED_TTL_S = 60

LIST_CHATS = "WHATSAPP_LIST_CHATS"
READ_CHAT = "WHATSAPP_READ_CHAT"

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": LIST_CHATS,
            "description": (
                "List the user's recent private WhatsApp chats (no groups), newest first: "
                "the person, when the last message came and what it said. Only the last "
                "7 days are known."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "description": "How many chats (1-50)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": READ_CHAT,
            "description": (
                "Read the messages of the user's private WhatsApp chat with someone, oldest "
                "first, each with who wrote it ('you' for the user) and when. Only the last "
                "7 days are known. Use it for 'what did Marco write me', 'did Ada answer'."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "person": {
                        "type": "string",
                        "description": "The person's name or part of it, as the user said it.",
                    },
                    "chat": {
                        "type": "string",
                        "description": "A chat id from WHATSAPP_LIST_CHATS, instead of a name.",
                    },
                    "since": {
                        "type": "string",
                        "description": "ISO date-time: only messages from then on.",
                    },
                    "limit": {"type": "integer", "description": "The latest N messages (1-200)."},
                },
                "required": [],
            },
        },
    },
]


def _count(value, default: int, most: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return max(1, min(number, most))


class WhatsAppProvider:
    """The two read tools, run against the bridge."""

    def __init__(self, bridge: whatsapp_bridge.WhatsAppBridge):
        self._bridge = bridge

    async def connected_toolkits(self, user_id: str, **kwargs) -> list[str]:
        return ["whatsapp"]

    async def tools_for(self, user_id: str, toolkits: list[str]) -> list[dict]:
        return list(TOOLS) if "whatsapp" in toolkits else []

    async def execute(self, user_id: str, tool: str, arguments: dict) -> ToolResult:
        owner = uuid.UUID(user_id)
        try:
            if tool == LIST_CHATS:
                chats = await self._bridge.chats(owner, _count(arguments.get("limit"), 20, 50))
                return ToolResult(ok=True, data={"chats": chats})
            if tool == READ_CHAT:
                person = str(arguments.get("person") or "").strip() or None
                chat = str(arguments.get("chat") or "").strip() or None
                if person is None and chat is None:
                    return ToolResult(ok=False, error="person or chat is required")
                messages = await self._bridge.messages(
                    owner,
                    chat=chat,
                    name=None if chat else person,
                    since=str(arguments.get("since") or "").strip() or None,
                    limit=_count(arguments.get("limit"), 100, 200),
                )
                if not messages:
                    return ToolResult(ok=True, data={
                        "messages": [],
                        "note": "No messages from this person in the last 7 days.",
                    })
                return ToolResult(ok=True, data={"messages": [
                    {
                        "from": "you" if m.get("from_me") else m.get("name"),
                        "chat": m.get("chat"),
                        "text": m.get("text"),
                        "at": m.get("at"),
                    }
                    for m in messages
                ]})
        except BridgeError as exc:
            return ToolResult(ok=False, error=f"WhatsApp could not be read: {exc}")
        return ToolResult(ok=False, error=f"Unknown tool: {tool}")


class WithWhatsApp:
    """Another provider (or none) plus WhatsApp."""

    def __init__(self, inner, whatsapp: WhatsAppProvider):
        self._inner = inner
        self._whatsapp = whatsapp

    def __getattr__(self, name):
        # Managing connections (Profile → Apps) stays the inner provider's
        if self._inner is None:
            raise AttributeError(name)
        return getattr(self._inner, name)

    async def connected_toolkits(self, user_id: str, **kwargs) -> list[str]:
        apps = (
            await self._inner.connected_toolkits(user_id, **kwargs)
            if self._inner is not None
            else []
        )
        return [*apps, *(["whatsapp"] if "whatsapp" not in apps else [])]

    async def tools_for(self, user_id: str, toolkits: list[str]) -> list[dict]:
        others = [t for t in toolkits if t != "whatsapp"]
        tools = (
            await self._inner.tools_for(user_id, others)
            if others and self._inner is not None
            else []
        )
        return [*tools, *(await self._whatsapp.tools_for(user_id, toolkits))]

    async def execute(self, user_id: str, tool: str, arguments: dict) -> ToolResult:
        if toolkit_of(tool) == "whatsapp":
            return await self._whatsapp.execute(user_id, tool, arguments)
        if self._inner is None:
            raise AccountNotConnectedError(toolkit_of(tool))
        return await self._inner.execute(user_id, tool, arguments)


async def whatsapp_linked(redis_client, user_id: uuid.UUID) -> bool:
    """Whether the user's WhatsApp is linked; the bridge is asked once a minute."""
    bridge = whatsapp_bridge.get_bridge()
    if bridge is None:
        return False
    key = LINKED_KEY.format(user_id=user_id)
    try:
        cached = await redis_client.get(key) if redis_client is not None else None
    except Exception:
        cached = None
    if cached is not None:
        return (cached.decode() if isinstance(cached, bytes) else str(cached)) == "1"
    try:
        linked = (await bridge.status(user_id)).get("state") == "linked"
    except BridgeError:
        logger.warning("WhatsApp bridge unreachable", exc_info=True)
        return False
    try:
        if redis_client is not None:
            await redis_client.set(key, "1" if linked else "0", ex=LINKED_TTL_S)
    except Exception:
        pass
    return linked


async def forget_linked(redis_client, user_id: uuid.UUID) -> None:
    """After linking or unlinking: the next request asks the bridge again."""
    try:
        if redis_client is not None:
            await redis_client.delete(LINKED_KEY.format(user_id=user_id))
    except Exception:
        pass


async def with_whatsapp(provider, redis_client, user_id: uuid.UUID):
    """`provider` plus WhatsApp while it is linked; otherwise `provider` itself."""
    if not await whatsapp_linked(redis_client, user_id):
        return provider
    return WithWhatsApp(provider, WhatsAppProvider(whatsapp_bridge.get_bridge()))
