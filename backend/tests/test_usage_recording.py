"""Each model call reports what it used: tokens for language and embedding models, seconds
of audio for transcription."""

import io
import logging
import wave
from types import SimpleNamespace

import pytest

from app.services import embedding_openai, llm_openai, stt_openai, usage, voice_embedding
from app.services.llm_base import LLMMessage

ns = SimpleNamespace

MESSAGES = [LLMMessage(role="user", content="ciao")]
TOOL = {"type": "function", "function": {"name": "t", "description": "", "parameters": {}}}


@pytest.fixture
def recorded(monkeypatch):
    calls = []

    async def record(kind, model, *, input_units=0, output_units=0, cached_units=0, **_):
        calls.append((kind, model, input_units, output_units, cached_units))

    for module in (llm_openai, embedding_openai, stt_openai, voice_embedding):
        monkeypatch.setattr(module, "record_usage", record)
    return calls


def _chat_usage():
    return ns(prompt_tokens=120, completion_tokens=30, total_tokens=150,
              prompt_tokens_details=ns(cached_tokens=64))


def _responses_usage():
    return ns(input_tokens=200, output_tokens=40, total_tokens=240,
              input_tokens_details=ns(cached_tokens=100))


class _Stream:
    def __init__(self, items):
        self._items = list(items)

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self._items:
            raise StopAsyncIteration
        return self._items.pop(0)


class _Create:
    """Answers `create`, remembering its keyword arguments."""

    def __init__(self, answer):
        self.answer = answer
        self.kwargs = []

    async def __call__(self, **kwargs):
        self.kwargs.append(kwargs)
        return self.answer(kwargs) if callable(self.answer) else self.answer


def _chat_service(answer, kind="llm_query"):
    service = llm_openai.OpenAILLMService("m", kind=kind)
    create = _Create(answer)
    service.client = ns(chat=ns(completions=ns(create=create)))
    return service, create


def _responses_service(answer, kind="llm_query"):
    service = llm_openai.OpenAIResponsesLLMService("m", kind=kind)
    create = _Create(answer)
    service.client = ns(responses=ns(create=create))
    return service, create


def _chat_reply(content="ok", tool_calls=None):
    return ns(
        choices=[ns(message=ns(content=content, tool_calls=tool_calls))],
        model="m", usage=_chat_usage(),
    )


def _responses_reply(text="ok"):
    return ns(output_text=text, model="m", usage=_responses_usage(), output=[])


async def test_chat_completion_records_input_output_and_cached(recorded):
    service, _ = _chat_service(_chat_reply())

    response = await service.complete(MESSAGES)

    assert recorded == [("llm_query", "m", 120, 30, 64)]
    assert (response.input_tokens, response.output_tokens, response.cached_tokens) == (120, 30, 64)


async def test_chat_stream_records_from_the_final_chunk(recorded):
    chunks = [
        ns(choices=[ns(delta=ns(content="Ci"))], usage=None),
        ns(choices=[ns(delta=ns(content="ao"))], usage=None),
        ns(choices=[], usage=_chat_usage()),
    ]
    service, create = _chat_service(lambda kwargs: _Stream(chunks))

    pieces = [piece async for piece in service.stream(MESSAGES)]

    assert pieces == ["Ci", "ao"]
    assert create.kwargs[0]["stream_options"] == {"include_usage": True}
    assert recorded == [("llm_query", "m", 120, 30, 64)]


async def test_responses_stream_records_on_completed(recorded):
    events = [
        ns(type="response.output_text.delta", delta="Ci"),
        ns(type="response.output_text.delta", delta="ao"),
        ns(type="response.completed", response=ns(usage=_responses_usage())),
    ]
    service, _ = _responses_service(lambda kwargs: _Stream(events))

    pieces = [piece async for piece in service.stream(MESSAGES)]

    assert pieces == ["Ci", "ao"]
    assert recorded == [("llm_query", "m", 200, 40, 100)]


async def test_complete_json_and_tools_record(recorded):
    chat, _ = _chat_service(_chat_reply('{"a": 1}'), kind="llm_intent")
    responses, _ = _responses_service(_responses_reply('{"a": 1}'), kind="llm_analysis")

    assert await chat.complete_json(MESSAGES) == {"a": 1}
    await chat.complete_with_tools(MESSAGES, [TOOL])
    assert await responses.complete_json(MESSAGES) == {"a": 1}
    await responses.complete_with_tools(MESSAGES, [TOOL])
    await responses.complete(MESSAGES)

    assert recorded == [
        ("llm_intent", "m", 120, 30, 64),
        ("llm_intent", "m", 120, 30, 64),
        ("llm_analysis", "m", 200, 40, 100),
        ("llm_analysis", "m", 200, 40, 100),
        ("llm_analysis", "m", 200, 40, 100),
    ]


def test_the_services_name_their_kind():
    assert llm_openai.openai_llm("m", api="chat", kind="llm_vision").kind == "llm_vision"
    assert llm_openai.openai_llm("m", api="responses", kind="llm_query").kind == "llm_query"


async def test_embedding_records_prompt_tokens(recorded):
    service = embedding_openai.OpenAIEmbeddingService()
    reply = ns(data=[ns(embedding=[0.1]), ns(embedding=[0.2])], usage=ns(prompt_tokens=42))
    service.client = ns(embeddings=ns(create=_Create(reply)))

    await service.embed("ciao")
    await service.embed_batch(["a", "b"])

    assert recorded == [
        ("embedding", service.model, 42, 0, 0),
        ("embedding", service.model, 42, 0, 0),
    ]


def _wav(seconds: float, rate: int = 16000) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(b"\x00\x00" * int(seconds * rate))
    return buffer.getvalue()


async def test_stt_records_seconds_from_the_wav(recorded):
    service = stt_openai.OpenAISTTService()
    service.client = ns(audio=ns(transcriptions=ns(create=_Create(ns(text="ciao")))))

    result = await service.transcribe(_wav(2.4))

    assert result.text == "ciao"
    assert recorded == [("stt", service.model, 3, 0, 0)]


def test_wav_seconds_round_up_and_survive_bad_audio():
    assert usage.wav_seconds(_wav(2.0)) == 2
    assert usage.wav_seconds(_wav(2.01)) == 3
    assert usage.wav_seconds(b"not a wav") == 0


async def test_a_failing_usage_write_still_returns_the_answer(monkeypatch, caplog):
    class _Broken:
        async def __aenter__(self):
            raise RuntimeError("database down")

        async def __aexit__(self, *exc):
            return False

    monkeypatch.setattr(usage, "async_session", _Broken)
    service, _ = _chat_service(_chat_reply("still here"))

    with caplog.at_level(logging.WARNING, logger="app.services.usage"):
        assert (await service.complete(MESSAGES)).content == "still here"
    # The write was really attempted, and failed
    assert any("Could not record model usage" in r.getMessage() for r in caplog.records)
