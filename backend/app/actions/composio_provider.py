"""Composio implementation of ActionProvider.

Verified against composio==0.15.0 / composio-client==1.39.0 (installed source). The default
`Composio(api_key=...)` provider already returns OpenAI ChatCompletionToolParam dicts, so
`composio_openai` is NOT needed (it would also force openai>=2.48; Echo pins openai==1.51.0).

SDK surface used (all synchronous):
- `connected_accounts.list(user_ids=[..], toolkit_slugs=[..], statuses=["ACTIVE"])` ->
  object with `.items`; each item has `.id`, `.status`, `.toolkit.slug`.
- `connected_accounts.link(user_id, auth_config_id, *, callback_url=None)` -> object with
  `.redirect_url` (`initiate()` is rejected for Composio-managed OAuth).
- `connected_accounts.delete(nanoid)`.
- `auth_configs.list(toolkit_slug=..)` -> `.items` (each `.id`, `.created_at`);
  `auth_configs.create(toolkit={"slug": s}, auth_config={"type": "use_composio_managed_auth",
  "tool_access_config": {"tools_for_connected_account_creation": []}})` -> `.auth_config.id`.
  (This is what `toolkits.authorize` does internally, so no COMPOSIO_AUTH_CONFIG_IDS setting.)
- `toolkits.get(slug)` -> object with `.slug`, `.name`, `.meta.description`;
  `toolkits.get(query={"search": q, "limit": n})` -> list of the same shape.
- `tools.get(user_id, toolkits=[..], limit=n)` / `tools.get(user_id, tools=[slugs])` -> list
  of OpenAI tool dicts, function.name = tool slug. `tools.get` has no "important" filter;
  the raw `client.tools.list(toolkit_slug="a,b", important="true", limit=n)` has (items with
  `.slug`).
- `tools.execute(slug, arguments, user_id=..., dangerously_skip_version_check=True)` ->
  dict `{"successful": bool, "data": dict, "error": str | None}`.
"""

import asyncio
import functools
import logging
from typing import Any

from app.actions.policy import CREATE_TOOLS, toolkit_of
from app.actions.provider import (
    INITIAL_TOOLKITS,
    AccountNotConnectedError,
    ActionOutcomeUnknown,
    ActionProviderError,
    Toolkit,
    ToolResult,
)
from app.core.config import settings

logger = logging.getLogger(__name__)

SDK_TIMEOUT_SECONDS = 20
SEARCH_LIMIT = 20
# Tool schemas offered to the model per request (token cost and tool-choice quality).
MAX_OFFERED_TOOLS = 100
# Always offered when their toolkit is connected: the create tools and the known
# send/reply/update/delete tools of the initial toolkits.
REQUIRED_TOOLS = (
    *sorted(CREATE_TOOLS),
    "GMAIL_SEND_EMAIL",
    "GMAIL_REPLY_TO_THREAD",
    "GMAIL_SEND_DRAFT",
    "GMAIL_FORWARD_MESSAGE",
    "GMAIL_DELETE_MESSAGE",
    "GMAIL_MOVE_TO_TRASH",
    "GOOGLECALENDAR_UPDATE_EVENT",
    "GOOGLECALENDAR_PATCH_EVENT",
    "GOOGLECALENDAR_DELETE_EVENT",
    "SLACK_SEND_MESSAGE",
    "SLACK_SENDS_A_MESSAGE_TO_A_SLACK_CHANNEL",
    "SLACK_UPDATES_A_SLACK_MESSAGE",
    "SLACK_DELETES_A_MESSAGE_FROM_A_CHAT",
    "TELEGRAM_SEND_MESSAGE",
    "TELEGRAM_EDIT_MESSAGE",
    "TELEGRAM_DELETE_MESSAGE",
    "TODOIST_UPDATE_TASK",
    "TODOIST_CLOSE_TASK",
    "TODOIST_DELETE_TASK",
    "NOTION_UPDATE_PAGE",
    "NOTION_ARCHIVE_NOTION_PAGE",
)


def _without_tracking(fn):
    """Wrap an SDK callable so it runs with SDK telemetry off.

    composio 0.15 reads `allow_tracking` from a ContextVar (default True) that
    `Composio(allow_tracking=False)` sets only in the context that built the client; a worker
    thread has its own context, so each call sets it itself.
    """

    @functools.wraps(fn)
    def run(*args, **kwargs):
        from composio.core.models.base import allow_tracking

        allow_tracking.set(False)
        return fn(*args, **kwargs)

    return run


async def _call(fn, *args, _executes: bool = False, **kwargs):
    """Run a sync SDK call in a thread with a timeout; never leak details or secrets.

    With `_executes`, a timeout (ours or the SDK's) raises ActionOutcomeUnknown: the
    request was sent and the action may still have happened.
    """
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(_without_tracking(functools.partial(fn, *args, **kwargs))),
            timeout=SDK_TIMEOUT_SECONDS,
        )
    except ActionProviderError:
        raise
    except TimeoutError as e:
        if _executes:
            raise ActionOutcomeUnknown("Composio request timed out") from e
        raise ActionProviderError("Composio request timed out") from e
    except Exception as e:
        logger.warning("Composio call failed: %s", type(e).__name__)
        if _executes and "timeout" in type(e).__name__.lower():
            raise ActionOutcomeUnknown(f"Composio request timed out ({type(e).__name__})") from e
        raise ActionProviderError(f"Composio request failed ({type(e).__name__})") from e


class ComposioActionProvider:
    def __init__(self, client: Any = None):
        self._client = client
        self._auth_config_ids: dict[str, str] = {}

    @property
    def client(self):
        if self._client is None:
            if not settings.composio_api_key:
                raise ActionProviderError("Composio is not configured")
            from composio import Composio

            # No SDK telemetry: it would send call metadata and errors to Composio
            self._client = Composio(api_key=settings.composio_api_key, allow_tracking=False)
        return self._client

    def _active_slugs(self, user_id: str, toolkit: str | None = None) -> list:
        kwargs: dict[str, Any] = {"user_ids": [user_id], "statuses": ["ACTIVE"]}
        if toolkit:
            kwargs["toolkit_slugs"] = [toolkit]
        return list(self.client.connected_accounts.list(**kwargs).items)

    def _auth_config_id(self, toolkit: str) -> str:
        cached = self._auth_config_ids.get(toolkit)
        if cached:
            return cached
        items = list(self.client.auth_configs.list(toolkit_slug=toolkit).items)
        if items:
            items.sort(key=lambda x: x.created_at, reverse=True)
            config_id = items[0].id
        else:
            config_id = self.client.auth_configs.create(
                toolkit={"slug": toolkit},
                auth_config={
                    "type": "use_composio_managed_auth",
                    "tool_access_config": {"tools_for_connected_account_creation": []},
                },
            ).auth_config.id
        self._auth_config_ids[toolkit] = config_id
        return config_id

    async def list_toolkits(self, user_id: str, query: str | None = None) -> list[Toolkit]:
        """Search results, or the initial toolkits plus any other connected toolkit."""
        accounts = await _call(self._active_slugs, user_id)
        connected_order = list(dict.fromkeys(a.toolkit.slug for a in accounts))
        connected = set(connected_order)

        def fetch() -> list[Toolkit]:
            if query:
                found = self.client.toolkits.get(query={"search": query, "limit": SEARCH_LIMIT})
                return [
                    Toolkit(t.slug, t.name, t.meta.description, t.slug in connected)
                    for t in found
                ]
            result = []
            # Toolkits connected through search are listed too, so they can be disconnected
            extra = [s for s in connected_order if s not in INITIAL_TOOLKITS]
            for slug in (*INITIAL_TOOLKITS, *extra):
                try:
                    t = self.client.toolkits.get(slug)
                    result.append(Toolkit(slug, t.name, t.meta.description, slug in connected))
                except Exception as e:
                    logger.warning("Composio toolkit lookup failed: %s", type(e).__name__)
                    result.append(Toolkit(slug, slug.title(), "", slug in connected))
            return result

        return await _call(fetch)

    async def connected_toolkits(self, user_id: str) -> list[str]:
        accounts = await _call(self._active_slugs, user_id)
        return list(dict.fromkeys(a.toolkit.slug for a in accounts))

    async def connect_link(self, user_id: str, toolkit: str, callback_url: str | None) -> str:
        def link() -> str:
            kwargs = {"callback_url": callback_url} if callback_url else {}
            request = self.client.connected_accounts.link(
                user_id, self._auth_config_id(toolkit), **kwargs
            )
            if not request.redirect_url:
                raise ActionProviderError("Composio returned no connect link")
            return request.redirect_url

        return await _call(link)

    async def disconnect(self, user_id: str, toolkit: str) -> None:
        def delete() -> None:
            for account in self._active_slugs(user_id, toolkit):
                self.client.connected_accounts.delete(account.id)

        await _call(delete)

    def _important_slugs(self, toolkits: list[str]) -> list[str]:
        """Composio's "important" (featured) tools of these toolkits.

        `tools.get` has no such filter in composio 0.15.0; the raw API listing does.
        """
        response = self.client.client.tools.list(
            toolkit_slug=",".join(toolkits), important="true", limit=MAX_OFFERED_TOOLS
        )
        return [item.slug for item in response.items]

    async def _best_effort(self, fn, *args, **kwargs) -> list:
        try:
            return list(await _call(fn, *args, **kwargs))
        except ActionProviderError:
            logger.warning("Composio tool lookup failed; offering the other tools")
            return []

    async def tools_for(self, user_id: str, toolkits: list[str]) -> list[dict]:
        """At most MAX_OFFERED_TOOLS schemas: required write tools, important ones, then
        the rest shared across the connected toolkits; initial toolkits first."""
        wanted = list(dict.fromkeys(toolkits))
        if not wanted:
            return []
        initial = [t for t in INITIAL_TOOLKITS if t in wanted]
        others = [t for t in wanted if t not in INITIAL_TOOLKITS]
        order = [*initial, *others]
        required = [s for s in REQUIRED_TOOLS if toolkit_of(s) in initial]
        get = self.client.tools.get

        async def none() -> list:
            return []

        required_tools, important, fill_initial, fill_others = await asyncio.gather(
            self._best_effort(get, user_id, tools=required) if required else none(),
            self._best_effort(self._important_slugs, initial) if initial else none(),
            _call(get, user_id, toolkits=initial, limit=MAX_OFFERED_TOOLS)
            if initial else none(),
            _call(get, user_id, toolkits=others, limit=MAX_OFFERED_TOOLS)
            if others else none(),
        )

        picked: dict[str, dict] = {}

        def add(schema) -> None:
            schema = dict(schema)
            name = schema.get("function", {}).get("name")
            if name and name not in picked and len(picked) < MAX_OFFERED_TOOLS:
                picked[name] = schema

        for schema in required_tools:
            add(schema)
        fill = [dict(t) for t in (*fill_initial, *fill_others)]
        by_name = {t.get("function", {}).get("name"): t for t in fill}
        missing = [s for s in important if s not in picked and s not in by_name]
        for slug in important:
            if slug in by_name:
                add(by_name[slug])
        if missing and len(picked) < MAX_OFFERED_TOOLS:
            for schema in await self._best_effort(get, user_id, tools=missing):
                add(schema)

        # Share the remaining slots round-robin so every connected toolkit gets tools
        buckets: dict[str, list[dict]] = {tk: [] for tk in order}
        for schema in fill:
            tk = toolkit_of(schema.get("function", {}).get("name", ""))
            buckets.setdefault(tk, []).append(schema)
        queues = [iter(b) for b in buckets.values()]
        while queues and len(picked) < MAX_OFFERED_TOOLS:
            for queue in list(queues):
                schema = next(queue, None)
                if schema is None:
                    queues.remove(queue)
                else:
                    add(schema)

        rank = {tk: i for i, tk in enumerate(order)}
        return sorted(
            picked.values(),
            key=lambda s: rank.get(toolkit_of(s["function"]["name"]), len(rank)),
        )

    async def execute(self, user_id: str, tool: str, arguments: dict) -> ToolResult:
        toolkit = toolkit_of(tool)
        accounts = await _call(self._active_slugs, user_id, toolkit)
        if not any(a.toolkit.slug == toolkit for a in accounts):
            raise AccountNotConnectedError(toolkit)
        result = await _call(
            self.client.tools.execute,
            tool,
            arguments,
            user_id=user_id,
            dangerously_skip_version_check=True,
            _executes=True,
        )
        if result.get("successful"):
            return ToolResult(ok=True, data=result.get("data"))
        return ToolResult(ok=False, error=str(result.get("error") or "Tool failed"))


@functools.cache
def get_action_provider() -> ComposioActionProvider:
    if not settings.composio_api_key:
        raise ActionProviderError("Composio is not configured")
    return ComposioActionProvider()
