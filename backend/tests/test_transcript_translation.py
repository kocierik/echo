"""Translating a conversation's transcript: lines carry their language, and the lines in
another language are translated into the user's, once each."""

import asyncio
import json
import uuid
from datetime import datetime, timezone

import pytest

from app.core.config import settings
from app.routers import conversations as conversations_router
from app.services.llm_base import LLMResponse
from app.services.transcription_editor import edit_transcription
from tests.factories import make_conversation
from tests.mocks import MockLLMService

STARTED = datetime(2026, 10, 27, 10, tzinfo=timezone.utc)


class _LLM(MockLLMService):
    def __init__(self, reply=None):
        super().__init__()
        self.reply = reply
        self.asked: list[dict] = []

    async def complete(self, messages, temperature=0.3):
        lines = json.loads(messages[-1].content)
        self.asked.append(lines)
        if self.reply is not None:
            return LLMResponse(content=self.reply, model="mock")
        translated = {key: f"IT: {text}" for key, text in lines.items()}
        return LLMResponse(content=json.dumps(translated), model="mock")


@pytest.fixture
def llm(monkeypatch):
    monkeypatch.setattr(settings, "stt_language", "it")
    fake = _LLM()
    monkeypatch.setattr(conversations_router, "get_llm_query_service", lambda: fake)
    return fake


async def _mixed(db):
    conversation, lines = await make_conversation(
        db,
        started_at=STARTED,
        texts=("[Self] Ciao Mark.", "[Others] See you tomorrow at nine.", "[Others] Great."),
    )
    lines[1].language = "en"
    lines[2].language = "en"
    await db.commit()
    return conversation, lines


async def test_lines_say_their_language(client, auth_headers, db_session, llm):
    conversation, _ = await _mixed(db_session)

    detail = (await client.get(f"/api/conversations/{conversation.id}", headers=auth_headers))

    assert [t["language"] for t in detail.json()["transcriptions"]] == ["it", "en", "en"]


async def test_only_the_foreign_lines_are_translated_once(client, auth_headers, db_session, llm):
    conversation, lines = await _mixed(db_session)
    url = f"/api/conversations/{conversation.id}/translate"

    first = await client.post(url, headers=auth_headers)

    assert first.status_code == 200
    assert first.json() == {
        "language": "it",
        "lines": {
            str(lines[1].segment_id): "IT: See you tomorrow at nine.",
            str(lines[2].segment_id): "IT: Great.",
        },
    }
    # The speaker tag is not translated
    assert list(llm.asked[0].values()) == ["See you tomorrow at nine.", "Great."]

    again = await client.post(url, headers=auth_headers)
    assert again.json() == first.json()
    assert len(llm.asked) == 1


async def test_a_conversation_in_the_users_language_asks_nothing(
    client, auth_headers, db_session, llm
):
    conversation, _ = await make_conversation(db_session, started_at=STARTED)
    await db_session.commit()

    response = await client.post(
        f"/api/conversations/{conversation.id}/translate", headers=auth_headers
    )

    assert response.json() == {"language": "it", "lines": {}}
    assert llm.asked == []


async def test_a_corrected_line_is_translated_again(client, auth_headers, db_session, llm):
    conversation, lines = await _mixed(db_session)
    url = f"/api/conversations/{conversation.id}/translate"
    await client.post(url, headers=auth_headers)

    await edit_transcription(
        db_session, conversation.user_id, lines[2].segment_id, "Great, thanks.", "other"
    )
    response = await client.post(url, headers=auth_headers)

    assert response.json()["lines"][str(lines[2].segment_id)] == "IT: Great, thanks."
    assert list(llm.asked[1].values()) == ["Great, thanks."]


async def test_a_long_conversation_is_translated_in_batches_at_once(
    client, auth_headers, db_session, monkeypatch
):
    monkeypatch.setattr(settings, "stt_language", "it")
    in_flight = 0
    most = 0

    class _Slow(_LLM):
        async def complete(self, messages, temperature=0.3):
            nonlocal in_flight, most
            in_flight += 1
            most = max(most, in_flight)
            await asyncio.sleep(0.05)
            in_flight -= 1
            return await super().complete(messages, temperature)

    slow = _Slow()
    monkeypatch.setattr(conversations_router, "get_llm_query_service", lambda: slow)
    conversation, lines = await make_conversation(
        db_session, started_at=STARTED, texts=tuple(f"[Others] Line {i}." for i in range(90))
    )
    for line in lines:
        line.language = "en"
    await db_session.commit()

    response = await client.post(
        f"/api/conversations/{conversation.id}/translate", headers=auth_headers
    )

    assert len(response.json()["lines"]) == 90
    assert len(slow.asked) == 3
    # Not one after the other: a long conversation fits the app's wait
    assert most > 1


@pytest.mark.parametrize("reply", ["not json", json.dumps({"1": "IT: Solo la prima."})])
async def test_a_bad_or_partial_answer_leaves_lines_untranslated(
    client, auth_headers, db_session, monkeypatch, reply
):
    monkeypatch.setattr(settings, "stt_language", "it")
    monkeypatch.setattr(conversations_router, "get_llm_query_service", lambda: _LLM(reply))
    conversation, lines = await _mixed(db_session)

    response = await client.post(
        f"/api/conversations/{conversation.id}/translate", headers=auth_headers
    )

    assert response.status_code == 200
    expected = {} if reply == "not json" else {str(lines[1].segment_id): "IT: Solo la prima."}
    assert response.json()["lines"] == expected


async def test_someone_elses_conversation_is_404(client, auth_headers, db_session, llm):
    conversation, _ = await make_conversation(
        db_session, started_at=STARTED, user_id=uuid.uuid4()
    )
    await db_session.commit()

    response = await client.post(
        f"/api/conversations/{conversation.id}/translate", headers=auth_headers
    )

    assert response.status_code == 404
