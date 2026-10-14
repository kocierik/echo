"""Test fixtures for integration tests."""

import asyncio
import hashlib
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import make_url, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.core.database import get_db, get_session_factory
from app.main import app
from app.models import Base
from tests.fakes.redis import InMemoryRedis

# The fixtures delete conversations, segments and entities after every test, so refuse
# any database whose name does not end in "_test" (the dev database is "echo").
TEST_DATABASE_URL = settings.database_url
_database_name = make_url(TEST_DATABASE_URL).database or ""
if not _database_name.endswith("_test"):
    raise pytest.UsageError(
        f"Refusing to run the tests on database {_database_name!r}: they delete its data. "
        "Point DATABASE_URL at a database ending in '_test' (`make test-all` uses echo_test)."
    )

test_engine = create_async_engine(TEST_DATABASE_URL, echo=False)
test_session = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)

# Never reach real services with the keys of the .env the containers load: the same values
# as CI (tests that need a provider stub it or set the key themselves)
settings.openai_api_key = "sk-test-not-real"
settings.composio_api_key = ""
settings.deepgram_api_key = ""
settings.metrics_token = ""

TEST_USER_ID = uuid.UUID("a0000000-0000-0000-0000-000000000001")
TEST_API_KEY = "test-secret-key"
TEST_API_KEY_HASH = hashlib.sha256(TEST_API_KEY.encode()).hexdigest()


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


@pytest_asyncio.fixture(autouse=True)
async def setup_database():
    """Create tables before tests, drop after."""
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # Insert test API key
        await conn.execute(
            text(
                "INSERT INTO api_keys (user_id, key_hash, name) "
                "VALUES (:user_id, :key_hash, 'test') "
                "ON CONFLICT (key_hash) DO NOTHING"
            ),
            {"user_id": str(TEST_USER_ID), "key_hash": TEST_API_KEY_HASH},
        )
        await conn.commit()

    yield

    async with test_engine.begin() as conn:
        # Clean up test data (but keep schema for next test)
        await conn.execute(text("DELETE FROM pending_actions"))
        await conn.execute(text("DELETE FROM photos"))
        await conn.execute(text("DELETE FROM entities"))
        await conn.execute(text("DELETE FROM chunks"))
        await conn.execute(text("DELETE FROM transcription_edits"))
        await conn.execute(text("DELETE FROM transcriptions"))
        await conn.execute(text("DELETE FROM segments"))
        await conn.execute(text("DELETE FROM conversations"))
        await conn.commit()


@pytest_asyncio.fixture
async def db_session():
    """Provide a test database session."""
    async with test_session() as session:
        yield session


async def override_get_db():
    async with test_session() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


app.dependency_overrides[get_db] = override_get_db
# Streaming endpoints open their own session: the test database too
app.dependency_overrides[get_session_factory] = lambda: test_session


@pytest_asyncio.fixture
async def client():
    """Provide an async HTTP test client.

    ASGITransport does not run the lifespan, so the app gets an in-memory Redis: the
    tests never push onto the real queues the worker reads.
    """
    had_redis = hasattr(app.state, "redis")
    original_redis = getattr(app.state, "redis", None)
    app.state.redis = InMemoryRedis()
    transport = ASGITransport(app=app)
    try:
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            yield ac
    finally:
        if had_redis:
            app.state.redis = original_redis
        else:
            del app.state.redis


@pytest.fixture
def auth_headers():
    """Headers with valid API key."""
    return {"X-API-Key": TEST_API_KEY}
