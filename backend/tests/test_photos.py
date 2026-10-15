"""Wearable camera: requests, upload, failures, the wearable's commands and analysis."""

import json
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ChatSession, Chunk, Conversation, Photo
from app.services import photos as photo_service
from app.services.conversation_reanalysis import reanalyse_conversation
from tests.conftest import TEST_USER_ID
from tests.test_conversation_reanalysis import (
    RecordingEmbeddings,
    RecordingLLM,
    _seed_reanalysis_data,
)

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64


class VisionLLM:
    def __init__(self, reply=None):
        self.reply = reply or {
            "answer": "È un ficus.",
            "description": "Una pianta verde in un vaso bianco, cartello 'FICUS 12 euro'.",
            "title": "Pianta in vaso",
        }
        self.messages = None

    async def complete_json(self, messages, temperature=0.1):
        self.messages = messages
        return self.reply


class Embeddings:
    def __init__(self):
        self.texts = []

    async def embed(self, text):
        self.texts.append(text)
        return [0.1] * 1536


async def _request(client, auth_headers, question=None) -> dict:
    body = {"question": question} if question else {}
    response = await client.post("/api/photos", headers=auth_headers, json=body)
    assert response.status_code == 201
    return response.json()


async def _upload(client, auth_headers, photo_id, data=JPEG, captured_at=None):
    captured_at = captured_at or datetime.now(timezone.utc)
    return await client.put(
        f"/api/photos/{photo_id}/image",
        headers={**auth_headers, "X-Captured-At": captured_at.isoformat()},
        files={"image": ("photo.jpg", data, "image/jpeg")},
    )


async def _last_voice_message(db: AsyncSession) -> dict:
    session = (
        await db.execute(
            select(ChatSession)
            .where(ChatSession.user_id == TEST_USER_ID, ChatSession.kind == "voice")
            .order_by(ChatSession.updated_at.desc())
            .execution_options(populate_existing=True)
        )
    ).scalars().first()
    return session.messages[-1]


async def _photo(db: AsyncSession, photo_id) -> Photo:
    result = await db.execute(
        select(Photo)
        .where(Photo.id == uuid.UUID(str(photo_id)))
        .execution_options(populate_existing=True)
    )
    return result.scalar_one()


@pytest.mark.asyncio
async def test_the_app_button_creates_a_request_and_the_upload_queues_it(client, auth_headers):
    photo = await _request(client, auth_headers)
    assert photo["status"] == "requested" and photo["source"] == "app"
    assert photo["chat_session_id"] is not None

    response = await _upload(client, auth_headers, photo["id"])

    assert response.status_code == 201
    assert response.json()["status"] == "received"
    redis = client._transport.app.state.redis
    assert redis.lists[photo_service.PHOTO_QUEUE] == [photo["id"]]

    # The app retries after a lost response: same image, same photo, not queued again
    again = await _upload(client, auth_headers, photo["id"])
    assert again.status_code == 200
    assert redis.lists[photo_service.PHOTO_QUEUE] == [photo["id"]]
    other = await _upload(client, auth_headers, photo["id"], data=JPEG + b"other")
    assert other.status_code == 409


@pytest.mark.asyncio
async def test_the_upload_takes_only_a_jpeg_within_the_limit(client, auth_headers, monkeypatch):
    photo = await _request(client, auth_headers)

    not_jpeg = await _upload(client, auth_headers, photo["id"], data=b"GIF89a....")
    assert not_jpeg.status_code == 400

    missing = await _upload(client, auth_headers, uuid.uuid4())
    assert missing.status_code == 404

    monkeypatch.setattr(photo_service.settings, "photo_max_bytes", 32)
    too_big = await _upload(client, auth_headers, photo["id"])
    assert too_big.status_code == 413


@pytest.mark.asyncio
async def test_a_failure_is_told_in_the_language_of_the_question(
    client, auth_headers, db_session
):
    photo = await _request(client, auth_headers, question="Che pianta è questa?")

    response = await client.post(
        f"/api/photos/{photo['id']}/failure", headers=auth_headers, json={"reason": "muted"}
    )

    assert response.json()["status"] == "failed"
    assert response.json()["error"] == "muted"
    message = await _last_voice_message(db_session)
    assert message["content"] == photo_service.TEXTS["it"]["muted"]
    assert message["notify"] is False  # asked from the app: no notification

    unknown = await client.post(
        f"/api/photos/{photo['id']}/failure", headers=auth_headers, json={"reason": "x"}
    )
    assert unknown.status_code == 422


@pytest.mark.asyncio
async def test_an_unanswered_request_times_out_but_a_late_image_is_still_taken(
    client, auth_headers, db_session
):
    photo = await _request(client, auth_headers)
    later = datetime.now(timezone.utc) + timedelta(
        seconds=photo_service.settings.photo_request_timeout_s + 5
    )

    expired = await photo_service.expire_photo_requests(db_session, now=later)

    assert expired == 1
    stored = await _photo(db_session, photo["id"])
    assert (stored.status, stored.error) == ("failed", "timeout")
    message = await _last_voice_message(db_session)
    assert message["content"] in {t["timeout"] for t in photo_service.TEXTS.values()}

    response = await _upload(client, auth_headers, photo["id"])
    assert response.status_code == 201 and response.json()["status"] == "received"


@pytest.mark.asyncio
async def test_device_commands_are_handed_out_once_and_expired_ones_dropped(
    client, auth_headers
):
    redis = client._transport.app.state.redis
    photo = SimpleNamespace(id=uuid.uuid4(), user_id=TEST_USER_ID)
    await photo_service.send_take_photo(redis, photo)
    key = photo_service.DEVICE_COMMANDS_KEY.format(user_id=TEST_USER_ID)
    stale = {
        "type": "take_photo",
        "photo_id": str(uuid.uuid4()),
        "expires_at": "2020-01-01T00:00:00+00:00",
    }
    await redis.rpush(key, json.dumps(stale))

    first = await client.get("/api/device/commands?wait=0", headers=auth_headers)
    second = await client.get("/api/device/commands?wait=0", headers=auth_headers)

    assert [c["photo_id"] for c in first.json()["commands"]] == [str(photo.id)]
    assert first.json()["commands"][0]["type"] == "take_photo"
    assert second.json()["commands"] == []
    too_long = await client.get("/api/device/commands?wait=60", headers=auth_headers)
    assert too_long.status_code == 422


@pytest.mark.asyncio
async def test_analysis_answers_in_the_chat_and_describes_the_photo_in_memory(
    client, auth_headers, db_session
):
    photo = await _request(client, auth_headers, question="Che pianta è questa?")
    await _upload(client, auth_headers, photo["id"])
    llm, embeddings = VisionLLM(), Embeddings()

    done = await photo_service.analyse_photo(db_session, uuid.UUID(photo["id"]), llm, embeddings)

    assert done is True
    assert llm.messages[-1].images == [JPEG]
    assert "Che pianta è questa?" in llm.messages[-1].content
    assert "Italian" in llm.messages[0].content
    stored = await _photo(db_session, photo["id"])
    assert stored.status == "done" and stored.answer == "È un ficus."

    # No conversation was going on: the photo gets its own, titled by the model
    conversation = await db_session.get(Conversation, stored.conversation_id)
    assert conversation.title == "Pianta in vaso" and conversation.emoji == "📷"
    chunk = (
        await db_session.execute(select(Chunk).where(Chunk.photo_id == stored.id))
    ).scalar_one()
    assert chunk.conversation_id == conversation.id
    assert "FICUS 12 euro" in chunk.text and "È un ficus." in chunk.text

    message = await _last_voice_message(db_session)
    assert message["content"] == "È un ficus."
    assert message["photo_id"] == photo["id"]
    assert message["notify"] is False

    # Already done: a duplicate queue item does nothing
    assert await photo_service.analyse_photo(
        db_session, uuid.UUID(photo["id"]), llm, embeddings
    ) is False


@pytest.mark.asyncio
async def test_a_photo_joins_the_conversation_going_on(client, auth_headers, db_session):
    now = datetime.now(timezone.utc)
    conversation = Conversation(
        user_id=TEST_USER_ID,
        started_at=now - timedelta(minutes=5),
        ended_at=now - timedelta(seconds=30),
        analysis_status="completed",
    )
    db_session.add(conversation)
    await db_session.commit()
    photo = await _request(client, auth_headers)
    await _upload(client, auth_headers, photo["id"], captured_at=now)

    await photo_service.analyse_photo(
        db_session, uuid.UUID(photo["id"]), VisionLLM(), Embeddings()
    )

    stored = await _photo(db_session, photo["id"])
    assert stored.conversation_id == conversation.id
    await db_session.refresh(conversation)
    assert conversation.ended_at >= now - timedelta(seconds=1)


@pytest.mark.asyncio
async def test_a_failed_analysis_is_told_and_the_image_stays_viewable(
    client, auth_headers, db_session
):
    photo = await _request(client, auth_headers)
    await _upload(client, auth_headers, photo["id"])

    await photo_service.fail_analysis(db_session, uuid.UUID(photo["id"]))

    stored = await _photo(db_session, photo["id"])
    assert (stored.status, stored.error) == ("failed", "analysis_failed")
    message = await _last_voice_message(db_session)
    assert message["photo_id"] == photo["id"]
    image = await client.get(f"/api/photos/{photo['id']}/image", headers=auth_headers)
    assert image.status_code == 200
    assert image.headers["content-type"] == "image/jpeg" and image.content == JPEG


@pytest.mark.asyncio
async def test_a_photo_without_image_has_no_image_to_download(client, auth_headers):
    photo = await _request(client, auth_headers)
    response = await client.get(f"/api/photos/{photo['id']}/image", headers=auth_headers)
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_voice_updates_notify_voice_photos_but_not_the_app_button(
    client, auth_headers, db_session
):
    since = datetime.now(timezone.utc) - timedelta(seconds=1)
    app_photo = await _request(client, auth_headers)
    session_id = uuid.UUID(app_photo["chat_session_id"])
    voice_photo = photo_service.request_photo(
        db_session, TEST_USER_ID, source="voice", chat_session_id=session_id, question="cos'è?"
    )
    await db_session.commit()
    for photo_id in (app_photo["id"], str(voice_photo.id)):
        await _upload(client, auth_headers, photo_id)
        await photo_service.analyse_photo(
            db_session, uuid.UUID(photo_id), VisionLLM(), Embeddings()
        )

    response = await client.get(
        "/api/actions/voice-updates",
        headers=auth_headers,
        params={"since": since.isoformat()},
    )

    photo_ids = [m["photo_id"] for m in response.json()["messages"]]
    assert photo_ids == [str(voice_photo.id)]


@pytest.mark.asyncio
async def test_reanalysis_keeps_the_photo_descriptions(db_session: AsyncSession, monkeypatch):
    import app.services.conversation_reanalysis as reanalysis_module

    async def direct_retry(coro_func, *args, **kwargs):
        kwargs.pop("operation_name", None)
        return await coro_func(*args, **kwargs)

    monkeypatch.setattr(reanalysis_module, "retry_with_backoff", direct_retry)
    conversation, *_ = await _seed_reanalysis_data(db_session)
    session = ChatSession(
        user_id=TEST_USER_ID,
        title="Voice requests",
        kind="voice",
        messages=[],
        created_at=datetime.now(timezone.utc),
        updated_at=datetime.now(timezone.utc),
    )
    db_session.add(session)
    await db_session.flush()
    photo = photo_service.request_photo(
        db_session, TEST_USER_ID, source="app", chat_session_id=session.id
    )
    photo.conversation_id = conversation.id
    await db_session.flush()
    db_session.add(
        Chunk(
            conversation_id=conversation.id,
            photo_id=photo.id,
            text="Photo taken on ...: a whiteboard",
            token_count=5,
            chunk_index=7,
            embedding=[0.0] * 1536,
        )
    )
    await db_session.commit()

    await reanalyse_conversation(db_session, conversation.id, RecordingLLM(), RecordingEmbeddings())

    chunks = (
        await db_session.execute(select(Chunk).where(Chunk.conversation_id == conversation.id))
    ).scalars().all()
    assert [c.photo_id for c in chunks if c.photo_id] == [photo.id]
    assert any(c.photo_id is None for c in chunks)  # the transcript was rebuilt too


@pytest.mark.asyncio
async def test_a_photo_asked_from_a_chat_is_answered_in_that_chat(
    client, auth_headers, db_session
):
    session = ChatSession(
        user_id=TEST_USER_ID,
        title="Plants",
        kind="chat",
        messages=[],
        created_at=datetime.now(timezone.utc),
        updated_at=datetime.now(timezone.utc),
    )
    db_session.add(session)
    await db_session.commit()

    response = await client.post(
        "/api/photos",
        headers=auth_headers,
        json={"question": "Che pianta è?", "chat_session_id": str(session.id)},
    )

    photo = response.json()
    assert photo["chat_session_id"] == str(session.id)
    await db_session.refresh(session)
    assert session.messages[-1]["role"] == "user"
    assert session.messages[-1]["content"] == "Che pianta è?"
    assert session.messages[-1]["photo_id"] == photo["id"]

    await _upload(client, auth_headers, photo["id"])
    await photo_service.analyse_photo(
        db_session, uuid.UUID(photo["id"]), VisionLLM(), Embeddings()
    )
    await db_session.refresh(session)
    assert session.messages[-1]["content"] == "È un ficus."

    unknown = await client.post(
        "/api/photos", headers=auth_headers, json={"chat_session_id": str(uuid.uuid4())}
    )
    assert unknown.status_code == 404


@pytest.mark.asyncio
async def test_a_photo_from_the_wearable_button_is_notified(client, auth_headers, db_session):
    response = await client.post("/api/photos", headers=auth_headers, json={"source": "button"})
    photo = response.json()
    assert photo["source"] == "button"
    await _upload(client, auth_headers, photo["id"])

    await photo_service.analyse_photo(
        db_session, uuid.UUID(photo["id"]), VisionLLM(), Embeddings()
    )

    message = await _last_voice_message(db_session)
    assert message["photo_id"] == photo["id"] and message["notify"] is True
    bad = await client.post("/api/photos", headers=auth_headers, json={"source": "voice"})
    assert bad.status_code == 422
