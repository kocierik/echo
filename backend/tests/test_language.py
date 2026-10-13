"""Unit tests: English app texts, answers in the language of the question."""

import uuid
from datetime import datetime, timezone

import pytest

from app.routers import query
from app.services import analysis_pipeline
from app.services.language import detect_language
from app.services.temporal import DateRange
from app.services.transcription_enhancer import speaker_prefix
from app.workers import digest

USER_ID = uuid.uuid4()


# --- Language of a message ---


@pytest.mark.parametrize(
    "text",
    [
        "Cosa mi ha detto Marco ieri?",
        "crea un evento domani alle 15",
        "sposta il dentista alle 18",
        "Che impegni ho questa settimana?",
    ],
)
def test_italian_messages(text):
    assert detect_language(text) == "it"


@pytest.mark.parametrize(
    "text",
    [
        "What did Marco tell me yesterday?",
        "Create an event tomorrow at 3pm",
        "move the dentist to 6pm",
        "",
        "Atlas?",
    ],
)
def test_english_or_unclear_messages_default_to_english(text):
    assert detect_language(text) == "en"


# --- Speaker prefix for new transcriptions ---


def test_speaker_prefixes_are_english():
    assert speaker_prefix("self") == "[You] "
    assert speaker_prefix("other") == "[Others] "
    assert speaker_prefix("unknown") == ""
    assert speaker_prefix(None) == ""


# --- RAG ---


def test_rag_prompt_answers_in_the_language_of_the_question():
    prompt = query.rag_system_prompt(None)

    assert "same language as the user's question" in prompt
    assert "italiano" not in prompt.lower()


def test_rag_prompt_mentions_the_period():
    period = DateRange(
        datetime(2026, 10, 1, tzinfo=timezone.utc), datetime(2026, 10, 13, tzinfo=timezone.utc)
    )

    assert "01/10/2026 - 13/10/2026" in query.rag_system_prompt(period)


def test_no_results_message_follows_the_question_language():
    assert query.no_results_message("What did Ada say?", None) == (
        "I don't have anything in your memory to answer this yet."
    )
    assert query.no_results_message("Cosa ha detto Ada?", None) == (
        "Non ho ancora informazioni nella memoria per rispondere a questa domanda."
    )
    period = DateRange(None, datetime(2026, 10, 13, tzinfo=timezone.utc))
    assert query.no_results_message("What happened?", period).startswith(
        "I couldn't find anything in your memory for that period."
    )


# --- Summaries and digest are in English ---


class _CapturingLLM:
    def __init__(self, result):
        self.result = result
        self.messages = None

    async def complete_json(self, messages):
        self.messages = messages
        return self.result


@pytest.mark.asyncio
async def test_conversation_summary_is_requested_in_english():
    llm = _CapturingLLM({})

    title, summary = await analysis_pipeline.generate_conversation_summary(llm, "Ciao Ada")

    assert "in English" in llm.messages[0].content
    assert title == "Untitled conversation"
    assert summary == ""


def test_digest_is_requested_in_english():
    assert "in English" in digest.DIGEST_SYSTEM_PROMPT
    assert digest.NO_SUMMARY == "No summary available."


@pytest.mark.asyncio
async def test_feedback_confirmation_is_english():
    from app.routers.feedback import FeedbackRequest, submit_feedback

    class _Db:
        def add(self, _obj):
            pass

    response = await submit_feedback(
        FeedbackRequest(session_id=str(uuid.uuid4()), message_index=1, rating="positive"),
        user_id=USER_ID,
        db=_Db(),
    )

    assert response.message == "Feedback saved. Thanks!"
    # The id must exist before the INSERT: the response is built before the flush
    assert isinstance(response.id, uuid.UUID)
