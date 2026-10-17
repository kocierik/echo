"""Reminders and Calendar on the user's phone, as action tools the app runs.

The app turns them on (Settings → On this iPhone; On this phone on Android, which has no
system Reminders app, so only the calendar) and reports which ones
(`PUT /device/phone-apps`, kept PHONE_APPS_TTL_S and reported again on every wake). A
call becomes a `phone_action` device command; the app runs it (EventKit on the iPhone, the
calendar provider on Android) and posts the result (`POST /device/commands/{id}/result`),
which `execute` waits for. A command the
app never picked up did nothing; one it picked up but did not answer in time may have
run, so the outcome is unknown and the user is told to check.

`with_phone_apps` adds these tools to Composio's only when the phone offers some: without
them chat and voice requests work exactly as before.
"""

import copy
import json
import logging
import uuid

from redis.exceptions import RedisError

from app.actions.policy import toolkit_of
from app.actions.provider import (
    AccountNotConnectedError,
    ActionOutcomeUnknown,
    ActionProviderError,
    Toolkit,
    ToolResult,
)
from app.services.device_commands import DELIVERED_KEY, push_device_command

logger = logging.getLogger(__name__)

PHONE_APP_NAMES = {
    "applereminders": "Phone Reminders",
    "applecalendar": "Phone Calendar",
}
PHONE_APPS_KEY = "phone:apps:{user_id}"
PHONE_APPS_TTL_S = 14 * 24 * 3600
# The app must pick a command up this soon; its answer is awaited a little longer, so
# one picked up at the last moment still has time to run
COMMAND_TTL_S = 15
RESULT_WAIT_S = 25
RESULT_KEY = "phone:result:{command_id}"
OWNER_KEY = "phone:owner:{command_id}"
RESULT_TTL_S = 120

_LOCAL_TIME = "local date-time 'YYYY-MM-DDTHH:MM'"


def _tool(name: str, description: str, properties: dict, required: list[str]) -> dict:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {"type": "object", "properties": properties, "required": required},
        },
    }


TOOLS: dict[str, dict] = {
    schema["function"]["name"]: schema
    for schema in (
        _tool(
            "APPLEREMINDERS_CREATE_REMINDER",
            "Create a reminder in the Reminders app on the user's phone. With a due time "
            "the phone alerts the user at that time.",
            {
                "title": {"type": "string", "description": "What to remember, short."},
                "due": {
                    "type": "string",
                    "description": f"When: {_LOCAL_TIME} (alert at that time) or date "
                    "'YYYY-MM-DD' (that day, no alert). Omit for no date.",
                },
                "notes": {"type": "string"},
                "list": {
                    "type": "string",
                    "description": "A Reminders list by name; the default list when omitted.",
                },
            },
            ["title"],
        ),
        _tool(
            "APPLEREMINDERS_LIST_REMINDERS",
            "List the open (not completed) reminders on the user's phone, soonest first.",
            {
                "due_before": {
                    "type": "string",
                    "description": f"Only reminders due before this {_LOCAL_TIME}.",
                },
                "query": {
                    "type": "string",
                    "description": "Only reminders whose title contains this text.",
                },
            },
            [],
        ),
        _tool(
            "APPLECALENDAR_CREATE_EVENT",
            "Create an event in the Calendar app on the user's phone. No invitation is sent.",
            {
                "title": {"type": "string"},
                "start": {
                    "type": "string",
                    "description": f"{_LOCAL_TIME}, or 'YYYY-MM-DD' for an all-day event.",
                },
                "end": {
                    "type": "string",
                    "description": "Same format as start; one hour after it when omitted.",
                },
                "location": {"type": "string"},
                "notes": {"type": "string"},
                "calendar": {
                    "type": "string",
                    "description": "A calendar by name; the default calendar when omitted.",
                },
            },
            ["title", "start"],
        ),
        _tool(
            "APPLECALENDAR_LIST_EVENTS",
            "List the events in the Calendar app on the user's phone between two times: "
            "every calendar on the phone, accounts added to it included.",
            {
                "start": {"type": "string", "description": f"{_LOCAL_TIME} or date."},
                "end": {
                    "type": "string",
                    "description": "Same format, after start and at most 31 days later.",
                },
                "query": {
                    "type": "string",
                    "description": "Only events whose title contains this text.",
                },
            },
            ["start", "end"],
        ),
    )
}


def _text(value) -> str | None:
    if isinstance(value, bytes):
        value = value.decode(errors="replace")
    return value if isinstance(value, str) else None


async def phone_apps(redis_client, user_id) -> list[str]:
    """The phone apps the app offers for this user; [] when it never said."""
    try:
        raw = _text(await redis_client.get(PHONE_APPS_KEY.format(user_id=user_id)))
    except RedisError as exc:
        raise ActionProviderError("Could not read the phone's apps") from exc
    try:
        apps = json.loads(raw) if raw else []
    except ValueError:
        return []
    return [app for app in apps if app in PHONE_APP_NAMES] if isinstance(apps, list) else []


async def set_phone_apps(redis_client, user_id, apps: list[str]) -> None:
    key = PHONE_APPS_KEY.format(user_id=user_id)
    await redis_client.set(
        key, json.dumps([app for app in PHONE_APP_NAMES if app in apps]), ex=PHONE_APPS_TTL_S
    )


async def record_phone_result(redis_client, user_id, command_id: str, result: dict) -> bool:
    """The app's answer to a command of this user; False for an unknown command."""
    owner = _text(await redis_client.get(OWNER_KEY.format(command_id=command_id)))
    if owner != str(user_id):
        return False
    key = RESULT_KEY.format(command_id=command_id)
    await redis_client.rpush(key, json.dumps(result))
    await redis_client.expire(key, RESULT_TTL_S)
    return True


class PhoneActionProvider:
    """The phone's Reminders and Calendar, run by the app (see the module docstring)."""

    def __init__(self, redis_client):
        self._redis = redis_client

    async def connected_toolkits(self, user_id: str) -> list[str]:
        return await phone_apps(self._redis, user_id)

    async def tools_for(self, user_id: str, toolkits: list[str]) -> list[dict]:
        return [
            copy.deepcopy(schema) for name, schema in TOOLS.items() if toolkit_of(name) in toolkits
        ]

    async def execute(self, user_id: str, tool: str, arguments: dict) -> ToolResult:
        if tool not in TOOLS:
            return ToolResult(ok=False, error=f"Unknown tool: {tool}")
        toolkit = toolkit_of(tool)
        if toolkit not in await self.connected_toolkits(user_id):
            raise AccountNotConnectedError(toolkit)
        command_id = uuid.uuid4().hex
        try:
            await self._redis.set(OWNER_KEY.format(command_id=command_id), user_id, ex=RESULT_TTL_S)
            await push_device_command(
                self._redis,
                user_id,
                {
                    "type": "phone_action",
                    "id": command_id,
                    "tool": tool,
                    "arguments": arguments if isinstance(arguments, dict) else {},
                },
                COMMAND_TTL_S,
            )
            answer = await self._redis.blpop(
                [RESULT_KEY.format(command_id=command_id)], timeout=RESULT_WAIT_S
            )
            delivered = answer is None and await self._redis.get(
                DELIVERED_KEY.format(command_id=command_id)
            )
        except RedisError as exc:
            raise ActionProviderError("Could not reach the phone") from exc
        if answer is None:
            if delivered:
                raise ActionOutcomeUnknown("The phone did not answer in time")
            raise ActionProviderError("The phone could not be reached: is the Echo app running?")
        try:
            result = json.loads(answer[1])
        except (TypeError, ValueError):
            return ToolResult(ok=False, unknown=True, error="unreadable answer from the phone")
        if result.get("ok") is True:
            return ToolResult(ok=True, data=result.get("data"))
        return ToolResult(ok=False, error=str(result.get("error") or "The phone could not do it"))


class WithPhoneApps:
    """Composio's apps (when configured) and the phone's, as one ActionProvider.

    The phone's apps are read once, when the request starts; managing connections
    (Settings → Automations → Integrations) is Composio's alone.
    """

    def __init__(self, composio, phone: PhoneActionProvider, phone_toolkits: list[str]):
        self._composio = composio
        self._phone = phone
        self._phone_toolkits = list(phone_toolkits)

    def _require_composio(self):
        if self._composio is None:
            raise ActionProviderError("Composio is not configured")
        return self._composio

    async def connected_toolkits(self, user_id: str, **kwargs) -> list[str]:
        apps = (
            await self._composio.connected_toolkits(user_id, **kwargs)
            if self._composio is not None
            else []
        )
        return [*apps, *(t for t in self._phone_toolkits if t not in apps)]

    async def tools_for(self, user_id: str, toolkits: list[str]) -> list[dict]:
        phone = [t for t in toolkits if t in PHONE_APP_NAMES]
        others = [t for t in toolkits if t not in PHONE_APP_NAMES]
        tools = (
            await self._composio.tools_for(user_id, others)
            if others and self._composio is not None
            else []
        )
        return [*tools, *(await self._phone.tools_for(user_id, phone))]

    async def execute(self, user_id: str, tool: str, arguments: dict) -> ToolResult:
        if toolkit_of(tool) in PHONE_APP_NAMES:
            return await self._phone.execute(user_id, tool, arguments)
        if self._composio is None:
            raise AccountNotConnectedError(toolkit_of(tool))
        return await self._composio.execute(user_id, tool, arguments)

    async def list_toolkits(self, user_id: str, query: str | None = None) -> list[Toolkit]:
        return await self._require_composio().list_toolkits(user_id, query)

    async def connect_link(self, user_id: str, toolkit: str, callback_url: str | None) -> str:
        return await self._require_composio().connect_link(user_id, toolkit, callback_url)

    async def disconnect(self, user_id: str, toolkit: str) -> None:
        await self._require_composio().disconnect(user_id, toolkit)


async def with_phone_apps(composio, redis_client, user_id) -> object | None:
    """`composio` (or None), plus the phone's apps when the app offers any.

    Without them the result is `composio` itself: nothing changes for a user who never
    turned them on. A Redis failure here only means no phone apps for this request.
    """
    phone = PhoneActionProvider(redis_client)
    try:
        apps = await phone.connected_toolkits(str(user_id))
    except ActionProviderError:
        logger.warning("Could not read the phone's apps", exc_info=True)
        apps = []
    if not apps:
        return composio
    return WithPhoneApps(composio, phone, apps)
