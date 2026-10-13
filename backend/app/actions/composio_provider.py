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
- `tools.get(user_id, toolkits=[..])` -> list of OpenAI tool dicts, function.name = tool slug.
- `tools.execute(slug, arguments, user_id=..., dangerously_skip_version_check=True)` ->
  dict `{"successful": bool, "data": dict, "error": str | None}`.
"""

import asyncio
import functools
import logging
from typing import Any

from app.actions.policy import toolkit_of
from app.actions.provider import (
    INITIAL_TOOLKITS,
    AccountNotConnectedError,
    ActionProviderError,
    Toolkit,
    ToolResult,
)
from app.core.config import settings

logger = logging.getLogger(__name__)

SDK_TIMEOUT_SECONDS = 20
SEARCH_LIMIT = 20


async def _call(fn, *args, **kwargs):
    """Run a sync SDK call in a thread with a timeout; never leak details or secrets."""
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(functools.partial(fn, *args, **kwargs)),
            timeout=SDK_TIMEOUT_SECONDS,
        )
    except ActionProviderError:
        raise
    except TimeoutError as e:
        raise ActionProviderError("Composio request timed out") from e
    except Exception as e:
        logger.warning("Composio call failed: %s", type(e).__name__)
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

            self._client = Composio(api_key=settings.composio_api_key)
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

    async def tools_for(self, user_id: str, toolkits: list[str]) -> list[dict]:
        if not toolkits:
            return []
        tools = await _call(self.client.tools.get, user_id, toolkits=list(toolkits))
        return [dict(t) for t in tools]

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
        )
        if result.get("successful"):
            return ToolResult(ok=True, data=result.get("data"))
        return ToolResult(ok=False, error=str(result.get("error") or "Tool failed"))


@functools.cache
def get_action_provider() -> ComposioActionProvider:
    if not settings.composio_api_key:
        raise ActionProviderError("Composio is not configured")
    return ComposioActionProvider()
