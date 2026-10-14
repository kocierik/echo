import json
from types import SimpleNamespace

import pytest

from app.services.llm_base import LLMMessage, LLMToolCall
from app.services.llm_openai import OpenAILLMService


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
