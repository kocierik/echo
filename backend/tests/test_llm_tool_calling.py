import json
from types import SimpleNamespace

import pytest

from app.services.llm_base import LLMMessage, LLMToolCall
from app.services.llm_openai import OpenAILLMService, OpenAIResponsesLLMService, openai_llm


class FakeCompletions:
    def __init__(self, tool_calls=None, content=None):
        self.kwargs: dict = {}
        self._tool_calls = tool_calls
        self._content = content

    async def create(self, **kwargs):
        self.kwargs = kwargs
        message = SimpleNamespace(content=self._content, tool_calls=self._tool_calls)
        return SimpleNamespace(
            choices=[SimpleNamespace(message=message)],
            model="gpt-test",
            usage=SimpleNamespace(total_tokens=42),
        )


def _service(completions: FakeCompletions) -> OpenAILLMService:
    service = OpenAILLMService.__new__(OpenAILLMService)
    service.model = "gpt-test"
    service.client = SimpleNamespace(chat=SimpleNamespace(completions=completions))
    return service


def _tool_call(arguments: str):
    return SimpleNamespace(
        id="c1",
        function=SimpleNamespace(name="GMAIL_FETCH_EMAILS", arguments=arguments),
    )


@pytest.mark.asyncio
async def test_tool_calls_are_parsed():
    completions = FakeCompletions(tool_calls=[_tool_call('{"max_results": 5}')])
    response = await _service(completions).complete_with_tools(
        [LLMMessage(role="user", content="mails?")], tools=[]
    )
    assert response.tool_calls == [LLMToolCall("c1", "GMAIL_FETCH_EMAILS", {"max_results": 5})]
    assert response.content == ""
    assert response.usage_tokens == 42


@pytest.mark.asyncio
async def test_tools_and_messages_are_sent_in_openai_format():
    completions = FakeCompletions(content="done")
    tools = [{"type": "function", "function": {"name": "GMAIL_FETCH_EMAILS"}}]
    messages = [
        LLMMessage(role="user", content="mails?"),
        LLMMessage(
            role="assistant",
            content="",
            tool_calls=[LLMToolCall("c1", "GMAIL_FETCH_EMAILS", {"max_results": 5})],
        ),
        LLMMessage(role="tool", content="[]", tool_call_id="c1"),
    ]
    response = await _service(completions).complete_with_tools(messages, tools=tools)

    kwargs = completions.kwargs
    assert kwargs["tools"] == tools
    assert kwargs["tool_choice"] == "auto"
    assert kwargs["messages"][0] == {"role": "user", "content": "mails?"}
    assistant = kwargs["messages"][1]
    assert assistant["role"] == "assistant"
    assert assistant["content"] is None
    assert assistant["tool_calls"] == [
        {
            "id": "c1",
            "type": "function",
            "function": {
                "name": "GMAIL_FETCH_EMAILS",
                "arguments": json.dumps({"max_results": 5}),
            },
        }
    ]
    assert kwargs["messages"][2] == {"role": "tool", "tool_call_id": "c1", "content": "[]"}
    assert response.content == "done"
    assert response.tool_calls == []


@pytest.mark.asyncio
async def test_invalid_tool_arguments_become_empty_dict():
    completions = FakeCompletions(tool_calls=[_tool_call("{not json")])
    response = await _service(completions).complete_with_tools(
        [LLMMessage(role="user", content="x")], tools=[]
    )
    assert response.tool_calls == [LLMToolCall("c1", "GMAIL_FETCH_EMAILS", {})]


@pytest.mark.asyncio
async def test_a_temperature_model_gets_its_temperature():
    completions = FakeCompletions(content="ok")
    service = _service(completions)

    await service.complete([LLMMessage(role="user", content="hi")], temperature=0.3)

    assert completions.kwargs["temperature"] == 0.3
    assert "extra_body" not in completions.kwargs


@pytest.mark.asyncio
async def test_a_reasoning_model_gets_its_effort_and_no_temperature():
    completions = FakeCompletions(content="ok")
    service = _service(completions)
    service.reasoning_effort = "none"

    await service.complete_with_tools([LLMMessage(role="user", content="hi")], tools=[])

    assert "temperature" not in completions.kwargs
    assert completions.kwargs["extra_body"] == {"reasoning_effort": "none"}


class FakeResponses:
    """client.responses: returns the given output items, or stream events with stream=True."""

    def __init__(self, output=None, output_text="", events=None):
        self.kwargs: dict = {}
        self._output = output or []
        self._output_text = output_text
        self._events = events or []

    async def create(self, **kwargs):
        self.kwargs = kwargs
        if kwargs.get("stream"):
            return self._stream()
        return SimpleNamespace(
            output=self._output,
            output_text=self._output_text,
            model="gpt-test",
            usage=SimpleNamespace(total_tokens=7),
        )

    async def _stream(self):
        for event in self._events:
            yield event


def _responses_service(responses: FakeResponses, reasoning_effort="low"):
    service = OpenAIResponsesLLMService.__new__(OpenAIResponsesLLMService)
    service.model = "gpt-test"
    service.reasoning_effort = reasoning_effort
    service.client = SimpleNamespace(responses=responses)
    return service


@pytest.mark.asyncio
async def test_responses_sends_tool_turns_as_items_and_flat_tools():
    responses = FakeResponses(output_text="done")
    tools = [
        {
            "type": "function",
            "function": {
                "name": "GMAIL_FETCH_EMAILS",
                "description": "Fetch mails",
                "parameters": {"type": "object", "properties": {"max_results": {}}},
            },
        }
    ]
    messages = [
        LLMMessage(role="system", content="Be brief."),
        LLMMessage(role="user", content="mails?"),
        LLMMessage(
            role="assistant",
            content="",
            tool_calls=[LLMToolCall("c1", "GMAIL_FETCH_EMAILS", {"max_results": 5})],
        ),
        LLMMessage(role="tool", content="[]", tool_call_id="c1"),
    ]

    response = await _responses_service(responses).complete_with_tools(messages, tools=tools)

    kwargs = responses.kwargs
    assert kwargs["input"] == [
        {"role": "system", "content": "Be brief."},
        {"role": "user", "content": "mails?"},
        {
            "type": "function_call",
            "call_id": "c1",
            "name": "GMAIL_FETCH_EMAILS",
            "arguments": json.dumps({"max_results": 5}),
        },
        {"type": "function_call_output", "call_id": "c1", "output": "[]"},
    ]
    assert kwargs["tools"] == [
        {
            "type": "function",
            "name": "GMAIL_FETCH_EMAILS",
            "description": "Fetch mails",
            "parameters": {"type": "object", "properties": {"max_results": {}}},
            "strict": False,
        }
    ]
    assert kwargs["reasoning"] == {"effort": "low"}
    assert "temperature" not in kwargs
    assert response.content == "done"
    assert response.tool_calls == []


@pytest.mark.asyncio
async def test_responses_reads_function_calls_from_the_output():
    responses = FakeResponses(
        output=[
            SimpleNamespace(type="reasoning"),
            SimpleNamespace(
                type="function_call",
                call_id="c2",
                name="TODOIST_CREATE_TASK",
                arguments='{"content": "Call Diego"}',
            ),
            SimpleNamespace(
                type="function_call", call_id="c3", name="search_memory", arguments="{bad"
            ),
        ]
    )

    response = await _responses_service(responses).complete_with_tools(
        [LLMMessage(role="user", content="x")], tools=[]
    )

    assert response.tool_calls == [
        LLMToolCall("c2", "TODOIST_CREATE_TASK", {"content": "Call Diego"}),
        LLMToolCall("c3", "search_memory", {}),
    ]
    assert response.usage_tokens == 7


@pytest.mark.asyncio
async def test_responses_streams_only_text_deltas():
    responses = FakeResponses(
        events=[
            SimpleNamespace(type="response.created"),
            SimpleNamespace(type="response.output_text.delta", delta="Mar"),
            SimpleNamespace(type="response.output_text.delta", delta="co"),
            SimpleNamespace(type="response.completed"),
        ]
    )

    pieces = [
        piece
        async for piece in _responses_service(responses).stream(
            [LLMMessage(role="user", content="x")]
        )
    ]

    assert pieces == ["Mar", "co"]


@pytest.mark.asyncio
async def test_responses_without_effort_sends_a_temperature():
    responses = FakeResponses(output_text='{"ok": true}')

    result = await _responses_service(responses, reasoning_effort="").complete_json(
        [LLMMessage(role="user", content="x")], temperature=0.1
    )

    assert result == {"ok": True}
    assert responses.kwargs["temperature"] == 0.1
    assert "reasoning" not in responses.kwargs
    assert responses.kwargs["text"] == {"format": {"type": "json_object"}}


def test_openai_llm_picks_the_api():
    assert isinstance(openai_llm("gpt-test", "low", "responses"), OpenAIResponsesLLMService)
    assert type(openai_llm("gpt-test")) is OpenAILLMService
    with pytest.raises(ValueError):
        openai_llm("gpt-test", api="soap")
