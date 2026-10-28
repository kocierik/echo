"""The WhatsApp bridge (whatsapp/, a Node service on the compose network): links the
user's number as a read-only device and keeps their private chats in its memory for 7
days. Every request carries the shared token; `get_bridge()` is None on a server
without one (`WHATSAPP_BRIDGE_URL` unset), and then nothing about WhatsApp shows.
"""

import uuid

import httpx

from app.core.config import settings


class BridgeError(Exception):
    """The bridge could not be reached or refused; `status` is its HTTP status, if any."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class WhatsAppBridge:
    def __init__(
        self, url: str, token: str, transport: httpx.AsyncBaseTransport | None = None
    ):
        self._url = url.rstrip("/")
        self._token = token
        self._transport = transport  # tests only

    async def _call(
        self,
        method: str,
        user_id: uuid.UUID,
        path: str = "",
        *,
        params: dict | None = None,
        body: dict | None = None,
        timeout: float = 10.0,
    ):
        try:
            async with httpx.AsyncClient(timeout=timeout, transport=self._transport) as client:
                response = await client.request(
                    method,
                    f"{self._url}/users/{user_id}{path}",
                    params={k: v for k, v in (params or {}).items() if v is not None},
                    json=body,
                    headers={"X-Bridge-Token": self._token},
                )
        except httpx.HTTPError as exc:
            raise BridgeError(f"WhatsApp bridge unreachable: {type(exc).__name__}") from exc
        if response.status_code >= 400:
            try:
                detail = response.json().get("error") or response.text
            except ValueError:
                detail = response.text
            raise BridgeError(str(detail), response.status_code)
        return response.json() if response.content else None

    async def status(self, user_id: uuid.UUID) -> dict:
        """{"state": "unlinked" | "linking" | "linked", "phone": "+39..." | None}"""
        return await self._call("GET", user_id, "/status", timeout=3.0)

    async def link(self, user_id: uuid.UUID, phone: str) -> str:
        """The pairing code the user types in WhatsApp → Linked devices."""
        data = await self._call("POST", user_id, "/link", body={"phone": phone}, timeout=30.0)
        return data["code"]

    async def unlink(self, user_id: uuid.UUID) -> None:
        await self._call("DELETE", user_id)

    async def chats(self, user_id: uuid.UUID, limit: int = 30) -> list[dict]:
        return (await self._call("GET", user_id, "/chats", params={"limit": limit}))["chats"]

    async def messages(
        self,
        user_id: uuid.UUID,
        *,
        chat: str | None = None,
        name: str | None = None,
        since: str | None = None,
        limit: int = 200,
    ) -> list[dict]:
        params = {"chat": chat, "name": name, "since": since, "limit": limit}
        return (await self._call("GET", user_id, "/messages", params=params))["messages"]


def get_bridge() -> WhatsAppBridge | None:
    if not settings.whatsapp_bridge_url:
        return None
    return WhatsAppBridge(settings.whatsapp_bridge_url, settings.whatsapp_bridge_token)
