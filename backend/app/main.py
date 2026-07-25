from contextlib import asynccontextmanager

import redis.asyncio as aioredis
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from sqlalchemy import text

from app.core.config import settings
from app.core.database import async_session, engine
from app.core.logging import new_correlation_id, setup_logging
from app.core.metrics import metrics
from app.routers import (
    admin,
    chat_sessions,
    conversations,
    digest,
    entities,
    feedback,
    query,
    segments,
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
    yield
    # Shutdown: close the pool
    await app.state.redis.aclose()


# Rate limiter: uses client IP by default, configurable via settings
limiter = Limiter(key_func=get_remote_address)

app = FastAPI(
    title="Echo - Second Brain API",
    description="Personal AI memory backend for the Second Brain wearable device.",
    version="0.1.0",
    lifespan=lifespan,
)

# Register rate limit exceeded handler
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

# API routes (must be before static mount)
app.include_router(segments.router, prefix=settings.api_prefix)
app.include_router(query.router, prefix=settings.api_prefix)
app.include_router(conversations.router, prefix=settings.api_prefix)
app.include_router(chat_sessions.router, prefix=settings.api_prefix)
app.include_router(entities.router, prefix=settings.api_prefix)
app.include_router(digest.router, prefix=settings.api_prefix)
app.include_router(admin.router, prefix=settings.api_prefix)
app.include_router(feedback.router, prefix=settings.api_prefix)


def get_redis(request: Request) -> aioredis.Redis:
    """Get the shared Redis client from app state."""
    return request.app.state.redis


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
async def stats():
    """System statistics: counts and storage usage."""
    async with async_session() as db:
        result = await db.execute(text("""
            SELECT
                (SELECT count(*) FROM segments) AS segments,
                (SELECT count(*) FROM transcriptions) AS transcriptions,
                (SELECT count(*) FROM conversations) AS conversations,
                (SELECT count(*) FROM entities) AS entities,
                (SELECT count(*) FROM chunks) AS chunks,
                (SELECT coalesce(sum(audio_size_bytes), 0)
                    FROM segments WHERE audio_path != '') AS audio_bytes
        """))
        row = result.one()

    return {
        "segments": row.segments,
        "transcriptions": row.transcriptions,
        "conversations": row.conversations,
        "entities": row.entities,
        "chunks": row.chunks,
        "audio_storage_mb": round(row.audio_bytes / (1024 * 1024), 2),
    }


@app.get("/metrics")
async def prometheus_metrics():
    """Prometheus-compatible metrics endpoint."""
    from fastapi.responses import PlainTextResponse

    return PlainTextResponse(metrics.export(), media_type="text/plain")


# Serve frontend static files (MUST be last — catches all unmatched routes)
app.mount("/", StaticFiles(directory="static", html=True), name="static")
