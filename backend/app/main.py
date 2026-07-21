from contextlib import asynccontextmanager

import redis.asyncio as aioredis
from fastapi import FastAPI, Request
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text

from app.core.config import settings
from app.core.database import async_session, engine
from app.routers import admin, conversations, entities, query, segments


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


app = FastAPI(
    title="Echo - Second Brain API",
    description="Personal AI memory backend for the Second Brain wearable device.",
    version="0.1.0",
    lifespan=lifespan,
)

# API routes (must be before static mount)
app.include_router(segments.router, prefix=settings.api_prefix)
app.include_router(query.router, prefix=settings.api_prefix)
app.include_router(conversations.router, prefix=settings.api_prefix)
app.include_router(entities.router, prefix=settings.api_prefix)
app.include_router(admin.router, prefix=settings.api_prefix)


def get_redis(request: Request) -> aioredis.Redis:
    """Get the shared Redis client from app state."""
    return request.app.state.redis


@app.get("/health")
async def health(request: Request):
    """Health check: verifies PostgreSQL and Redis connectivity."""
    status = {"status": "ok", "postgres": "ok", "redis": "ok"}

    # Check PostgreSQL
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
    except Exception as e:
        status["postgres"] = f"error: {str(e)[:100]}"
        status["status"] = "degraded"

    # Check Redis
    try:
        await request.app.state.redis.ping()
    except Exception as e:
        status["redis"] = f"error: {str(e)[:100]}"
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


# Serve frontend static files (MUST be last — catches all unmatched routes)
app.mount("/", StaticFiles(directory="static", html=True), name="static")
