import asyncio
import hmac
import uuid
from contextlib import asynccontextmanager

import redis.asyncio as aioredis
from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlalchemy import text

from app.actions.composio_provider import preload_sdk
from app.core.auth import get_current_user_id
from app.core.config import settings
from app.core.database import async_session, engine
from app.core.logging import new_correlation_id, setup_logging
from app.core.metrics import metrics
from app.core.rate_limit import limiter
from app.mcp.server import mcp_endpoint
from app.routers import (
    actions,
    admin,
    auth,
    chat_sessions,
    conversations,
    device,
    digest,
    entities,
    export,
    feedback,
    firmware,
    notifications,
    people,
    photos,
    query,
    search,
    segments,
    voices,
)

# Configure structured JSON logging on import
setup_logging()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage shared resources (Redis pool) across the app lifecycle."""
    # Startup: create shared Redis connection pool
    app.state.redis = aioredis.from_url(
        settings.redis_url,
        decode_responses=False,
        max_connections=20,
    )
    preload = asyncio.create_task(preload_sdk())
    yield
    # Shutdown: close the pool
    preload.cancel()
    await app.state.redis.aclose()


app = FastAPI(
    title="Echo - Second Brain API",
    description="Personal AI memory backend for the Second Brain wearable device.",
    version="0.1.0",
    lifespan=lifespan,
)

# One shared limiter (per API key, else per IP): the routers decorate with the same one
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# CORS — allow configured origins (default: "*" for development)
cors_origins = [o.strip() for o in settings.cors_origins.split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-Correlation-ID"],
)


@app.middleware("http")
async def correlation_id_middleware(request: Request, call_next):
    """Assign a correlation ID to each request and track metrics."""
    import time

    cid = new_correlation_id()
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start

    response.headers["X-Correlation-ID"] = cid

    # Track request metrics
    metrics.inc("http_requests_total")
    metrics.observe("http_request_duration_seconds", duration)
    if response.status_code >= 400:
        metrics.inc("http_errors_total")

    return response

# API routes
app.include_router(auth.router, prefix=settings.api_prefix)
app.include_router(segments.router, prefix=settings.api_prefix)
app.include_router(query.router, prefix=settings.api_prefix)
app.include_router(conversations.router, prefix=settings.api_prefix)
app.include_router(chat_sessions.router, prefix=settings.api_prefix)
app.include_router(entities.router, prefix=settings.api_prefix)
app.include_router(export.router, prefix=settings.api_prefix)
app.include_router(digest.router, prefix=settings.api_prefix)
app.include_router(admin.router, prefix=settings.api_prefix)
app.include_router(feedback.router, prefix=settings.api_prefix)
app.include_router(notifications.router, prefix=settings.api_prefix)
app.include_router(actions.router, prefix=settings.api_prefix)
app.include_router(search.router, prefix=settings.api_prefix)
app.include_router(people.router, prefix=settings.api_prefix)
app.include_router(photos.router, prefix=settings.api_prefix)
app.include_router(voices.router, prefix=settings.api_prefix)
app.include_router(firmware.router, prefix=settings.api_prefix)
app.include_router(device.router, prefix=settings.api_prefix)

# Connected apps (Claude, Cursor…): the memory over MCP, read-only (app/mcp/server.py)
for _mcp_path in ("/mcp", "/mcp/"):
    app.router.add_route(_mcp_path, mcp_endpoint, methods=["GET", "POST", "DELETE"])


@app.get("/health")
async def health(request: Request):
    """Health check: verifies PostgreSQL, Redis, queue depth, and circuit breaker."""
    from app.core.circuit_breaker import openai_breaker

    status = {"status": "ok", "postgres": "ok", "redis": "ok"}

    # Check PostgreSQL
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
    except Exception as e:
        status["postgres"] = f"error: {str(e)[:100]}"
        status["status"] = "degraded"

    # Check Redis + queue lengths
    try:
        redis_client = request.app.state.redis
        await redis_client.ping()

        # Queue depths — useful to detect worker lag
        stt_queue_len = await redis_client.llen("queue:stt")
        analysis_queue_len = await redis_client.llen("queue:analysis")
        dead_letter_len = await redis_client.llen("queue:dead-letter")

        status["queues"] = {
            "stt": stt_queue_len,
            "analysis": analysis_queue_len,
            "dead_letter": dead_letter_len,
        }

        # Warn if queues are backing up
        if stt_queue_len > 50 or analysis_queue_len > 50:
            status["status"] = "degraded"
            status["warning"] = "Queue backlog detected — worker may be slow or down"

    except Exception as e:
        status["redis"] = f"error: {str(e)[:100]}"
        status["status"] = "degraded"

    # Circuit breaker status
    status["circuit_breaker"] = openai_breaker.status()
    if openai_breaker.state.value == "open":
        status["status"] = "degraded"

    return status


@app.get("/api/stats")
async def stats(user_id: uuid.UUID = Depends(get_current_user_id)):
    """Counts and storage usage for the authenticated user's memory."""
    async with async_session() as db:
        result = await db.execute(
            text("""
            SELECT
                (SELECT count(*) FROM segments WHERE user_id = :uid) AS segments,
                (SELECT count(*) FROM transcriptions t
                    JOIN segments s ON s.id = t.segment_id
                    WHERE s.user_id = :uid) AS transcriptions,
                (SELECT count(*) FROM conversations WHERE user_id = :uid) AS conversations,
                (SELECT count(*) FROM entities WHERE user_id = :uid) AS entities,
                (SELECT count(*) FROM chunks c
                    JOIN conversations cv ON cv.id = c.conversation_id
                    WHERE cv.user_id = :uid) AS chunks,
                (SELECT coalesce(sum(audio_size_bytes), 0) FROM segments
                    WHERE user_id = :uid AND audio_path != '') AS audio_bytes
            """),
            {"uid": user_id},
        )
        row = result.one()

    return {
        "segments": row.segments,
        "transcriptions": row.transcriptions,
        "conversations": row.conversations,
        "entities": row.entities,
        "chunks": row.chunks,
        "audio_storage_mb": round(row.audio_bytes / (1024 * 1024), 2),
    }


async def _authorize_metrics(request: Request) -> None:
    """Bearer METRICS_TOKEN when configured (for Prometheus), else a valid API key."""
    from fastapi import HTTPException

    if settings.metrics_token:
        expected = f"Bearer {settings.metrics_token}"
        provided = request.headers.get("authorization", "")
        if hmac.compare_digest(provided.encode(), expected.encode()):
            return
    api_key = request.headers.get("x-api-key")
    if api_key:
        async with async_session() as db:
            await get_current_user_id(request, api_key=api_key, db=db)
        return
    raise HTTPException(status_code=401, detail="Not authenticated")


@app.get("/metrics", dependencies=[Depends(_authorize_metrics)])
async def prometheus_metrics():
    """Prometheus-compatible metrics endpoint."""
    from fastapi.responses import PlainTextResponse

    return PlainTextResponse(metrics.export(), media_type="text/plain")
