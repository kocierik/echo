"""Profile → Example data: on makes a few days of conversations (queued for the analysis
worker), facts, saved things and places; off deletes exactly those, and the user's own
data stays."""

import uuid
from datetime import date, datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select

from app.core.timezone import to_user_local_date
from app.main import app
from app.models.conversation import Conversation
from app.models.digest import Digest
from app.models.health_day import HealthDay
from app.models.place_visit import PlaceVisit
from app.models.saved import SavedItem, SavedList
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.models.user import User
from app.models.user_fact import UserFact
from app.routers import demo
from app.services import demo_data
from app.services.analysis_pipeline import assign_to_conversation
from tests.conftest import TEST_USER_ID, test_session


class _Embeddings:
    async def embed(self, text):
        return [0.1] * 1536


@pytest.fixture(autouse=True)
def _no_openai():
    app.dependency_overrides[demo.embeddings] = lambda: _Embeddings()
    yield
    app.dependency_overrides.pop(demo.embeddings, None)


async def _account(language="it"):
    async with test_session() as db:
        db.add(User(id=TEST_USER_ID, email="erik@example.com", password_hash="x",
                    language=language))
        await db.commit()


async def _count(model, *where):
    async with test_session() as db:
        return await db.scalar(select(func.count()).select_from(model).where(*where))


async def _set(client, auth_headers, on):
    response = await client.put("/api/demo", headers=auth_headers, json={"on": on})
    assert response.status_code == 200
    return response.json()["on"]


async def test_on_makes_the_examples_and_queues_their_speech(client, auth_headers):
    await _account("it")
    assert (await client.get("/api/demo", headers=auth_headers)).json() == {"on": False}

    assert await _set(client, auth_headers, True) is True

    content = demo_data.ITALIAN
    assert await _count(Conversation) == len(content.conversations)
    lines = sum(len(c.lines) for c in content.conversations)
    assert await _count(Segment, Segment.transcription_status == "completed") == lines
    assert await _count(UserFact, UserFact.status == "kept") == len(content.facts)
    assert await _count(SavedItem) == len(content.saved)
    assert await _count(PlaceVisit) == len(content.places)
    assert await _count(HealthDay, HealthDay.source == "demo") == 7
    async with test_session() as db:
        texts = list(await db.scalars(select(Transcription.text)))
        newest = await db.scalar(select(func.max(Conversation.started_at)))
    assert any("Lisbona" in text for text in texts)
    # All in the past: the summaries worker closes them at once
    assert newest < datetime.now(timezone.utc) - timedelta(hours=2)
    queued = app.state.redis.lists[demo_data.ANALYSIS_QUEUE]
    assert len(queued) == lines
    assert (await client.get("/api/demo", headers=auth_headers)).json() == {"on": True}


async def test_an_english_account_gets_english_examples(client, auth_headers):
    await _account("en")

    await _set(client, auth_headers, True)

    async with test_session() as db:
        facts = list(await db.scalars(select(UserFact.text)))
    assert set(facts) == set(demo_data.ENGLISH.facts)


async def test_on_twice_makes_one_set(client, auth_headers):
    await _account()

    await _set(client, auth_headers, True)
    await _set(client, auth_headers, True)

    assert await _count(Conversation) == len(demo_data.ITALIAN.conversations)
    assert await _count(UserFact) == len(demo_data.ITALIAN.facts)


async def test_off_deletes_the_examples_and_keeps_the_users_own(client, auth_headers):
    await _account()
    now = datetime.now(timezone.utc)
    async with test_session() as db:
        own = Conversation(id=uuid.uuid4(), user_id=TEST_USER_ID, started_at=now,
                           ended_at=now, analysis_status="completed")
        db.add(own)
        db.add(UserFact(user_id=TEST_USER_ID, text="Mine", status="kept", source="you"))
        db.add(SavedList(id=uuid.uuid4(), user_id=TEST_USER_ID, name="Vini"))
        await db.commit()

    await _set(client, auth_headers, True)
    # The user saves their own wine in the list the examples share
    async with test_session() as db:
        wines = await db.scalar(select(SavedList).where(SavedList.name == "Vini"))
        db.add(SavedItem(user_id=TEST_USER_ID, list_id=wines.id, title="Lambrusco",
                         source="chat"))
        await db.commit()

    assert await _set(client, auth_headers, False) is False

    async with test_session() as db:
        conversations = list(await db.scalars(select(Conversation.id)))
        facts = list(await db.scalars(select(UserFact.text)))
        items = list(await db.scalars(select(SavedItem.title)))
        lists = set(await db.scalars(select(SavedList.name)))
    assert conversations == [own.id]
    assert facts == ["Mine"]
    assert items == ["Lambrusco"]
    # The lists the examples started go, the one the user had stays
    assert lists == {"Vini"}
    assert await _count(Segment) == 0
    assert await _count(PlaceVisit) == 0
    assert await _count(HealthDay) == 0
    assert (await client.get("/api/demo", headers=auth_headers)).json() == {"on": False}


async def test_off_deletes_the_summaries_written_over_the_examples(client, auth_headers):
    await _account()
    await _set(client, auth_headers, True)
    async with test_session() as db:
        started = list(await db.scalars(select(Conversation.started_at)))
        demo_day = to_user_local_date(min(started))
        db.add(Digest(user_id=TEST_USER_ID, digest_date=demo_day, summary="with examples",
                      people=[], tasks=[], ideas=[], events=[], conversation_count=1))
        db.add(Digest(user_id=TEST_USER_ID, digest_date=date(2020, 1, 1), summary="old",
                      people=[], tasks=[], ideas=[], events=[], conversation_count=1))
        await db.commit()

    removed = None

    async def capture(user_id, gone):
        nonlocal removed
        removed = gone

    original = demo._rewrite_summaries
    demo._rewrite_summaries = capture
    try:
        await _set(client, auth_headers, False)
    finally:
        demo._rewrite_summaries = original

    async with test_session() as db:
        left = list(await db.scalars(select(Digest.summary)))
    assert left == ["old"]
    assert removed is not None and removed.days == [demo_day]


async def test_the_worker_keeps_each_line_in_its_example_conversation(client, auth_headers):
    await _account()
    await _set(client, auth_headers, True)

    async with test_session() as db:
        segments = list(await db.scalars(select(Segment).order_by(Segment.recorded_at)))
        expected = {segment.id: segment.conversation_id for segment in segments}
        # As the analysis worker groups them, oldest first
        for segment in segments:
            conversation = await assign_to_conversation(db, segment)
            assert conversation.id == expected[segment.id]
        await db.rollback()
