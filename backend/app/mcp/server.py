"""The MCP server at /mcp (Streamable HTTP, stateless, JSON responses).

Only connected apps' read keys get in (`authenticate_connected_app`), at most
MCP_CALLS_PER_MINUTE calls a minute per key; each call runs as the key's user, for the
tools (`current_mcp_key`) and for the usage table (`usage_owner`). Tools: app/mcp/tools.py.

Each request gets its own short-lived session manager: stateless requests share nothing,
and this needs no lifespan (the tests' client does not run one either).
"""

import logging
import uuid
from contextvars import ContextVar
from dataclasses import dataclass

from fastapi import HTTPException
from mcp.server.fastmcp import FastMCP
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse

from app.core.auth import authenticate_connected_app, reserve_attempt
from app.core.database import async_session
from app.models.mcp_call import McpCall
from app.services.usage import usage_owner

logger = logging.getLogger(__name__)

MCP_CALLS_PER_MINUTE = 60

INSTRUCTIONS = (
    "Echo is the user's memory: their conversations, the people in them, their tasks and "
    "promises, and daily and weekly summaries. Read-only."
)

server = FastMCP("Echo", instructions=INSTRUCTIONS, stateless_http=True, json_response=True)


@dataclass(frozen=True)
class McpCaller:
    """The connected app making this call."""

    key_id: uuid.UUID
    user_id: uuid.UUID


current_mcp_key: ContextVar[McpCaller | None] = ContextVar("current_mcp_key", default=None)


async def log_call(tool: str, summary: str) -> None:
    """Notes a tool call for the calling key; a failure is logged, never raised."""
    caller = current_mcp_key.get()
    if caller is None:
        return
    try:
        async with async_session() as db:
            db.add(McpCall(api_key_id=caller.key_id, tool=tool[:40], summary=summary[:200]))
            await db.commit()
    except Exception:
        logger.warning("Could not log the MCP call %s", tool, exc_info=True)


async def _refuse(scope, receive, send, status: int, detail: str, headers=None) -> None:
    await JSONResponse({"detail": detail}, status_code=status, headers=headers)(
        scope, receive, send
    )


class _McpApp:
    """ASGI app for /mcp: authenticate, limit, then the MCP SDK (a class, so Starlette
    hands it the raw ASGI call instead of treating it as a request-response endpoint)."""

    async def __call__(self, scope, receive, send) -> None:
        await _serve(scope, receive, send)


async def _serve(scope, receive, send) -> None:
    request = Request(scope, receive)
    async with async_session() as db:
        try:
            key = await authenticate_connected_app(request, db)
        except HTTPException as error:
            return await _refuse(
                scope, receive, send, error.status_code, error.detail, error.headers
            )
        caller = McpCaller(key_id=key.id, user_id=key.user_id)
        await db.commit()  # last_used_at

    redis = getattr(request.app.state, "redis", None)
    if redis is not None:
        seconds = await reserve_attempt(
            redis, f"mcp_calls:{caller.key_id}", limit=MCP_CALLS_PER_MINUTE, window=60
        )
        if seconds is not None:
            return await _refuse(
                scope, receive, send, 429, "Too many calls. Try again in a minute.",
                {"Retry-After": str(seconds)},
            )

    caller_token = current_mcp_key.set(caller)
    owner_token = usage_owner.set(caller.user_id)
    try:
        manager = StreamableHTTPSessionManager(
            app=server._mcp_server,
            json_response=True,
            stateless=True,
            # Behind the tunnel the Host is the public name; the key is the protection
            security_settings=TransportSecuritySettings(enable_dns_rebinding_protection=False),
        )
        async with manager.run():
            await manager.handle_request(scope, receive, send)
    finally:
        usage_owner.reset(owner_token)
        current_mcp_key.reset(caller_token)


mcp_endpoint = _McpApp()
