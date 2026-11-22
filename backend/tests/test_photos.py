"""Wearable camera: requests, upload, failures, the wearable's commands and analysis."""

import hashlib
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
from app.services.device_commands import DEVICE_COMMANDS_KEY
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
    key = DEVICE_COMMANDS_KEY.format(user_id=TEST_USER_ID)
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
    # Asked with the app's camera button, not by voice
    assert session.messages[-1]["source"] == "camera"

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


class AnalysisLLM:
    """Entity extraction for photo descriptions; never confirms a duplicate."""

    def __init__(self, entities=None, fail=False):
        self.entities = entities if entities is not None else [
            {
                "type": "event",
                "name": "Riunione Q4",
                "content": "Riunione sul quarto trimestre",
                "metadata": {"event_date": "2026-10-15", "event_time": "15:00"},
            }
        ]
        self.fail = fail
        self.texts = []

    async def complete_json(self, messages, temperature=0.1):
        if self.fail:
            raise RuntimeError("model down")
        self.texts.append(messages[-1].content)
        return {"entities": self.entities}

    async def complete(self, messages, temperature=0.3):
        from app.services.llm_base import LLMResponse

        return LLMResponse(content="no", model="fake")


class _BatchEmbeddings(Embeddings):
    async def embed_batch(self, texts):
        return [[0.1] * 1536 for _ in texts]


async def _analysed(client, auth_headers, db_session, vision=None, analysis=None):
    photo = await _request(client, auth_headers)
    await _upload(client, auth_headers, photo["id"])
    await photo_service.analyse_photo(
        db_session,
        uuid.UUID(photo["id"]),
        vision or VisionLLM(),
        _BatchEmbeddings(),
        analysis_llm=analysis or AnalysisLLM(),
    )
    return await _photo(db_session, photo["id"])


@pytest.mark.asyncio
async def test_what_a_photo_shows_becomes_entities(client, auth_headers, db_session):
    from app.models import Entity, EntityMention

    analysis = AnalysisLLM()
    photo = await _analysed(client, auth_headers, db_session, analysis=analysis)

    assert "FICUS 12 euro" in analysis.texts[0]
    event = (
        await db_session.execute(select(Entity).where(Entity.name == "Riunione Q4"))
    ).scalar_one()
    assert event.entity_type == "event"
    assert event.metadata_["photo_id"] == str(photo.id)
    assert event.conversation_id == photo.conversation_id
    mention = (
        await db_session.execute(select(EntityMention).where(EntityMention.entity_id == event.id))
    ).scalar_one()
    assert mention.conversation_id == photo.conversation_id


@pytest.mark.asyncio
async def test_a_business_card_becomes_a_person(client, auth_headers, db_session):
    from app.models import Entity

    card = VisionLLM({
        "answer": "È il biglietto da visita di Giulia Bianchi.",
        "description": "Biglietto: Giulia Bianchi, Designer, Acme, giulia@acme.it",
        "title": "Biglietto da visita",
        "contact": {
            "name": "Giulia Bianchi",
            "role": "Designer",
            "company": "Acme",
            "email": "giulia@acme.it",
            "phone": "",
        },
    })
    # Extraction finds the same person in the description: the card's details win
    found_again = [{"type": "person", "name": "Giulia Bianchi", "content": "Designer presso Acme"}]
    photo = await _analysed(
        client, auth_headers, db_session, vision=card, analysis=AnalysisLLM(entities=found_again)
    )

    person = (
        await db_session.execute(select(Entity).where(Entity.name == "Giulia Bianchi"))
    ).scalar_one()
    assert person.entity_type == "person"
    assert person.content == "Designer, Acme"
    assert person.metadata_["email"] == "giulia@acme.it" and "phone" not in person.metadata_
    assert photo.answer.endswith("Aggiunto alle tue persone: Giulia Bianchi.")
    message = await _last_voice_message(db_session)
    assert message["content"] == photo.answer

    # The same card again completes the same person
    card.reply = {**card.reply, "contact": {"name": "giulia bianchi", "phone": "+39 333"}}
    await _analysed(client, auth_headers, db_session, vision=card, analysis=AnalysisLLM([]))
    people = (
        await db_session.execute(select(Entity).where(Entity.entity_type == "person"))
    ).scalars().all()
    assert len(people) == 1
    await db_session.refresh(people[0])
    assert people[0].metadata_["phone"] == "+39 333"
    assert people[0].metadata_["email"] == "giulia@acme.it"


@pytest.mark.asyncio
async def test_failing_entities_never_lose_the_answer(client, auth_headers, db_session):
    photo = await _analysed(client, auth_headers, db_session, analysis=AnalysisLLM(fail=True))

    assert photo.status == "done" and photo.answer == "È un ficus."
    chunk = (
        await db_session.execute(select(Chunk).where(Chunk.photo_id == photo.id))
    ).scalar_one()
    assert "FICUS" in chunk.text


@pytest.mark.asyncio
async def test_the_answer_is_sent_before_what_the_photo_shows_is_remembered(
    client, auth_headers, db_session
):
    """Extracting entities takes several model calls: the user does not wait for them."""
    from tests.conftest import test_session

    seen = []

    class _Watching(AnalysisLLM):
        async def complete_json(self, messages, temperature=0.1):
            async with test_session() as other:
                seen.append((await other.execute(select(Photo.status))).scalars().all())
            return await super().complete_json(messages, temperature)

    await _analysed(client, auth_headers, db_session, analysis=_Watching())

    assert seen and seen[0] == ["done"]


@pytest.mark.asyncio
async def test_a_photo_asked_by_voice_tells_the_phone_before_remembering_what_it_shows(
    client, auth_headers, db_session
):
    told = []

    async def answered(user_id):
        told.append(user_id)

    class _Late(AnalysisLLM):
        async def complete_json(self, messages, temperature=0.1):
            assert told, "the phone is told before the entities are extracted"
            return await super().complete_json(messages, temperature)

    photo = await _request(client, auth_headers)
    await _upload(client, auth_headers, photo["id"])
    row = await db_session.get(Photo, uuid.UUID(photo["id"]))
    row.source = "voice"
    await db_session.commit()

    await photo_service.analyse_photo(
        db_session, uuid.UUID(photo["id"]), VisionLLM(), _BatchEmbeddings(),
        analysis_llm=_Late(), answered=answered,
    )

    assert told == [TEST_USER_ID]


@pytest.mark.asyncio
async def test_photos_in_the_conversation_and_in_the_list(client, auth_headers, db_session):
    photo = await _analysed(client, auth_headers, db_session)

    detail = await client.get(
        f"/api/conversations/{photo.conversation_id}", headers=auth_headers
    )
    photos = detail.json()["photos"]
    assert [p["id"] for p in photos] == [str(photo.id)]
    assert photos[0]["answer"] == "È un ficus."
    entities = detail.json()["entities"]
    assert any(e["metadata_"].get("photo_id") == str(photo.id) for e in entities)

    listed = await client.get("/api/conversations", headers=auth_headers)
    item = next(c for c in listed.json()["conversations"] if c["id"] == str(photo.conversation_id))
    assert item["photo_count"] == 1
    # Today shows a photo row with its image
    assert item["photo_id"] == str(photo.id)


@pytest.mark.asyncio
async def test_reanalysis_keeps_what_photos_showed(db_session: AsyncSession, monkeypatch):
    import app.services.conversation_reanalysis as reanalysis_module
    from app.models import Entity, EntityMention

    async def direct_retry(coro_func, *args, **kwargs):
        kwargs.pop("operation_name", None)
        return await coro_func(*args, **kwargs)

    monkeypatch.setattr(reanalysis_module, "retry_with_backoff", direct_retry)
    conversation, *_ = await _seed_reanalysis_data(db_session)
    from_photo = Entity(
        user_id=TEST_USER_ID,
        entity_type="person",
        name="Giulia Bianchi",
        metadata_={"photo_id": str(uuid.uuid4()), "email": "giulia@acme.it"},
        conversation_id=conversation.id,
    )
    db_session.add(from_photo)
    await db_session.commit()

    await reanalyse_conversation(db_session, conversation.id, RecordingLLM(), RecordingEmbeddings())

    kept = await db_session.get(Entity, from_photo.id)
    assert kept is not None and kept.metadata_["email"] == "giulia@acme.it"
    mention = (
        await db_session.execute(
            select(EntityMention).where(EntityMention.entity_id == from_photo.id)
        )
    ).scalar_one()
    assert mention.conversation_id == conversation.id


@pytest.mark.asyncio
async def test_voice_working_lists_requests_and_photos_on_their_way(client, auth_headers):
    from app.actions.voice import WORKING_KEY

    redis = client._transport.app.state.redis
    await redis.hset(
        WORKING_KEY.format(user_id=TEST_USER_ID),
        "seg-1",
        json.dumps({"command": "che impegni ho domani?", "since": "2026-10-15T10:00:00+00:00"}),
    )
    photo = await _request(client, auth_headers, question="Che pianta è?")

    response = await client.get("/api/actions/voice-working", headers=auth_headers)

    items = response.json()["items"]
    assert [(i["kind"], i["text"]) for i in items] == [
        ("request", "che impegni ho domani?"),
        ("photo", "Che pianta è?"),
    ]
    assert items[1]["session_id"] == photo["chat_session_id"]


@pytest.mark.asyncio
async def test_a_photo_from_the_phone_is_accepted_and_analysed(client, auth_headers, db_session):
    response = await client.post(
        "/api/photos", headers=auth_headers, json={"question": "Cos'è?", "source": "phone"}
    )
    assert response.status_code == 201
    photo = response.json()
    await _upload(client, auth_headers, photo["id"])

    done = await photo_service.analyse_photo(
        db_session, uuid.UUID(photo["id"]), VisionLLM(), Embeddings()
    )

    assert done is True
    assert (await _photo(db_session, photo["id"])).source == "phone"


async def _answered_photo(client, auth_headers, db_session, reply=None, question=None) -> dict:
    photo = await _request(client, auth_headers, question=question)
    await _upload(client, auth_headers, photo["id"])
    await photo_service.analyse_photo(
        db_session, uuid.UUID(photo["id"]), VisionLLM(reply), Embeddings()
    )
    return photo


@pytest.mark.asyncio
async def test_the_answer_keeps_the_date_the_photo_shows(client, auth_headers, db_session):
    reply = {
        "answer": "L'ascensore è fermo fino a giovedì 23.",
        "description": "Avviso: ascensore fuori servizio fino al 23/10.",
        "title": "Avviso ascensore",
        "when": "2026-10-23T09:00",
    }

    photo = await _answered_photo(client, auth_headers, db_session, reply, "spiegami questo")

    message = await _last_voice_message(db_session)
    assert message["photo_id"] == photo["id"]
    assert message["when"] == "2026-10-23T09:00:00"
    thread = (await client.get("/api/chat-sessions/thread", headers=auth_headers)).json()
    assert thread["messages"][-1]["when"] == "2026-10-23T09:00:00"


@pytest.mark.parametrize("when", ["giovedì", "", None, 23, "2026-13-40"])
def test_a_bad_when_is_dropped(when):
    assert photo_service.parse_when(when) is None


def test_an_aware_when_is_kept_as_local_time():
    # The user's zone (Europe/Rome, summer time on 23 October)
    assert photo_service.parse_when("2026-10-23T07:00:00+00:00") == "2026-10-23T09:00:00"


def test_vision_prompt_does_what_was_asked_and_names_the_date():
    prompt = photo_service.VISION_PROMPT.format(language="Italian")
    assert '"when"' in prompt
    assert "translate" in prompt and "explain" in prompt


def test_vision_prompt_never_guesses_in_a_poor_photo_and_notices_a_turned_pendant():
    # A dark photo's pale monstera leaf came back as "a hand holding banknotes"
    prompt = photo_service.VISION_PROMPT.format(language="Italian")
    assert "never guess" in prompt
    assert "not facing forward" in prompt


@pytest.mark.asyncio
async def test_a_follow_up_is_answered_from_the_same_image(
    client, auth_headers, db_session, monkeypatch
):
    photo = await _answered_photo(client, auth_headers, db_session, question="Che pianta è?")
    llm = VisionLLM({"answer": "It's a ficus."})
    monkeypatch.setattr("app.routers.photos.get_llm_vision_service", lambda: llm)

    response = await client.post(
        f"/api/photos/{photo['id']}/ask", headers=auth_headers, json={"question": "Translate it"}
    )

    assert response.status_code == 200
    assert response.json()["answer"] == "It's a ficus."
    assert response.json()["session_id"] == photo["chat_session_id"]
    assert llm.messages[-1].images == [JPEG]
    assert "Translate it" in llm.messages[-1].content
    assert "È un ficus." in llm.messages[-1].content  # the first answer, as context
    session = await db_session.get(
        ChatSession, uuid.UUID(photo["chat_session_id"]), populate_existing=True
    )
    question, answer = session.messages[-2:]
    assert question["content"] == "Translate it" and question["source"] == "chat"
    assert question["about_photo_id"] == photo["id"]
    assert answer["content"] == "It's a ficus." and answer["notify"] is False
    assert answer["about_photo_id"] == photo["id"] and "photo_id" not in answer


@pytest.mark.asyncio
async def test_a_follow_up_needs_an_image_of_ones_own(client, auth_headers, db_session):
    waiting = await _request(client, auth_headers)
    other = Photo(
        id=uuid.uuid4(), user_id=uuid.uuid4(), status="done", source="app",
        image=JPEG, image_sha256="x", created_at=datetime.now(timezone.utc),
    )
    db_session.add(other)
    await db_session.commit()

    for photo_id in (waiting["id"], str(other.id), str(uuid.uuid4())):
        response = await client.post(
            f"/api/photos/{photo_id}/ask", headers=auth_headers, json={"question": "E questo?"}
        )
        assert response.status_code == 404
    empty = await client.post(
        f"/api/photos/{waiting['id']}/ask", headers=auth_headers, json={"question": ""}
    )
    assert empty.status_code == 422



def _jpeg(level: int) -> bytes:
    import io

    from PIL import Image

    out = io.BytesIO()
    Image.new("RGB", (64, 48), (level, level, level)).save(out, "JPEG")
    return out.getvalue()


def _mean(jpeg: bytes) -> float:
    import io

    from PIL import Image, ImageStat

    return ImageStat.Stat(Image.open(io.BytesIO(jpeg)).convert("L")).mean[0]


def test_a_dark_photo_is_brightened_and_a_bright_one_kept():
    dark, bright = _jpeg(25), _jpeg(140)

    assert _mean(photo_service.brighten(dark)) > 90
    assert photo_service.brighten(bright) == bright
    # Not a picture Pillow reads: kept as it is
    assert photo_service.brighten(b"\xff\xd8\xff garbage") == b"\xff\xd8\xff garbage"


def test_a_brightened_upload_is_still_recognised_when_sent_again():
    photo = Photo(user_id=TEST_USER_ID, source="voice", status="requested")
    dark = _jpeg(25)

    photo_service.store_image(photo, dark, datetime.now(timezone.utc))

    assert photo.image != dark and photo.size_bytes == len(photo.image)
    assert photo.image_sha256 == hashlib.sha256(dark).hexdigest()
