import base64
import functools
import json
from collections.abc import AsyncIterator

from openai import AsyncOpenAI

from app.core.config import settings
from app.services.llm_base import LLMMessage, LLMResponse, LLMService, LLMToolCall


def _data_url(image: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(image).decode("ascii")


def _to_openai_message(m: LLMMessage) -> dict:
    if m.role == "tool":
        return {"role": "tool", "tool_call_id": m.tool_call_id, "content": m.content}
    if m.tool_calls:
        return {
            "role": m.role,
            "content": m.content or None,
            "tool_calls": [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {"name": tc.name, "arguments": json.dumps(tc.arguments)},
                }
                for tc in m.tool_calls
            ],
        }
    if m.images:
        return {
            "role": m.role,
            "content": [
                {"type": "text", "text": m.content},
                *(
                    {"type": "image_url", "image_url": {"url": _data_url(image)}}
                    for image in m.images
                ),
            ],
        }
    return {"role": m.role, "content": m.content}


def _parse_arguments(raw: str | None) -> dict:
    try:
        parsed = json.loads(raw or "{}")
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


class OpenAILLMService(LLMService):
    """OpenAI GPT LLM implementation.

    With a `reasoning_effort` (reasoning models), the effort is sent and the
    temperature is not: those models accept only their default temperature.
    """

    reasoning_effort = ""

    def __init__(self, model: str, reasoning_effort: str = ""):
        self.client = AsyncOpenAI(api_key=settings.openai_api_key)
        self.model = model
        self.reasoning_effort = reasoning_effort

    def _sampling(self, temperature: float) -> dict:
        if self.reasoning_effort:
            # Not a named argument in the pinned SDK: sent as is
            return {"extra_body": {"reasoning_effort": self.reasoning_effort}}
        return {"temperature": temperature}

    async def complete(self, messages: list[LLMMessage], temperature: float = 0.3) -> LLMResponse:
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[_to_openai_message(m) for m in messages],
            **self._sampling(temperature),
        )
        choice = response.choices[0]
        return LLMResponse(
            content=choice.message.content or "",
            model=response.model,
            usage_tokens=response.usage.total_tokens if response.usage else None,
        )

    async def stream(
        self, messages: list[LLMMessage], temperature: float = 0.3
    ) -> AsyncIterator[str]:
        chunks = await self.client.chat.completions.create(
            model=self.model,
            messages=[_to_openai_message(m) for m in messages],
            stream=True,
            **self._sampling(temperature),
        )
        async for chunk in chunks:
            if chunk.choices and (piece := chunk.choices[0].delta.content):
                yield piece

    async def complete_json(
        self, messages: list[LLMMessage], temperature: float = 0.1
    ) -> dict:
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[_to_openai_message(m) for m in messages],
            response_format={"type": "json_object"},
            **self._sampling(temperature),
        )
        content = response.choices[0].message.content or "{}"
        return json.loads(content)

    async def complete_with_tools(
        self, messages: list[LLMMessage], tools: list[dict], temperature: float = 0.2
    ) -> LLMResponse:
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[_to_openai_message(m) for m in messages],
            tools=tools,
            tool_choice="auto",
            **self._sampling(temperature),
        )
        message = response.choices[0].message
        return LLMResponse(
            content=message.content or "",
            model=response.model,
            usage_tokens=response.usage.total_tokens if response.usage else None,
            tool_calls=[
                LLMToolCall(
                    id=tc.id,
                    name=tc.function.name,
                    arguments=_parse_arguments(tc.function.arguments),
                )
                for tc in (message.tool_calls or [])
            ],
        )


def _to_response_items(messages: list[LLMMessage]) -> list[dict]:
    """Chat-style messages as Responses API input items."""
    items: list[dict] = []
    for m in messages:
        if m.role == "tool":
            items.append(
                {"type": "function_call_output", "call_id": m.tool_call_id, "output": m.content}
            )
            continue
        if m.images:
            items.append(
                {
                    "role": m.role,
                    "content": [
                        {"type": "input_text", "text": m.content},
                        *(
                            {"type": "input_image", "image_url": _data_url(image)}
                            for image in m.images
                        ),
                    ],
                }
            )
        elif m.content or not m.tool_calls:
            items.append({"role": m.role, "content": m.content})
        for tc in m.tool_calls or []:
            items.append(
                {
                    "type": "function_call",
                    "call_id": tc.id,
                    "name": tc.name,
                    "arguments": json.dumps(tc.arguments),
                }
            )
    return items


def _to_response_tool(tool: dict) -> dict:
    """A chat completions tool ({"type", "function": {...}}) in the Responses shape."""
    function = tool.get("function", tool)
    return {
        "type": "function",
        "name": function["name"],
        "description": function.get("description", ""),
        "parameters": function.get("parameters", {"type": "object", "properties": {}}),
        "strict": False,
    }


class OpenAIResponsesLLMService(LLMService):
    """OpenAI through the Responses API.

    Reasoning models (gpt-6) accept function tools together with a reasoning effort only
    here, not on chat completions. The same messages and tools as the chat service are
    translated to Responses items.
    """

    def __init__(self, model: str, reasoning_effort: str = ""):
        self.client = AsyncOpenAI(api_key=settings.openai_api_key)
        self.model = model
        self.reasoning_effort = reasoning_effort

    def _options(self, temperature: float) -> dict:
        if self.reasoning_effort:
            return {"reasoning": {"effort": self.reasoning_effort}}
        return {"temperature": temperature}

    async def complete(self, messages: list[LLMMessage], temperature: float = 0.3) -> LLMResponse:
        response = await self.client.responses.create(
            model=self.model, input=_to_response_items(messages), **self._options(temperature)
        )
        return LLMResponse(
            content=response.output_text or "",
            model=response.model,
            usage_tokens=response.usage.total_tokens if response.usage else None,
        )

    async def stream(
        self, messages: list[LLMMessage], temperature: float = 0.3
    ) -> AsyncIterator[str]:
        events = await self.client.responses.create(
            model=self.model,
            input=_to_response_items(messages),
            stream=True,
            **self._options(temperature),
        )
        async for event in events:
            if event.type == "response.output_text.delta" and event.delta:
                yield event.delta

    async def complete_json(
        self, messages: list[LLMMessage], temperature: float = 0.1
    ) -> dict:
        response = await self.client.responses.create(
            model=self.model,
            input=_to_response_items(messages),
            text={"format": {"type": "json_object"}},
            **self._options(temperature),
        )
        return json.loads(response.output_text or "{}")

    async def complete_with_tools(
        self, messages: list[LLMMessage], tools: list[dict], temperature: float = 0.2
    ) -> LLMResponse:
        response = await self.client.responses.create(
            model=self.model,
            input=_to_response_items(messages),
            tools=[_to_response_tool(tool) for tool in tools],
            tool_choice="auto",
            **self._options(temperature),
        )
        return LLMResponse(
            content=response.output_text or "",
            model=response.model,
            usage_tokens=response.usage.total_tokens if response.usage else None,
            tool_calls=[
                LLMToolCall(
                    id=item.call_id, name=item.name, arguments=_parse_arguments(item.arguments)
                )
                for item in response.output
                if item.type == "function_call"
            ],
        )


def openai_llm(model: str, reasoning_effort: str = "", api: str = "chat") -> LLMService:
    """The OpenAI service for an `api` of "chat" (chat completions) or "responses"."""
    if api == "responses":
        return OpenAIResponsesLLMService(model, reasoning_effort)
    if api == "chat":
        return OpenAILLMService(model, reasoning_effort)
    raise ValueError(f"Unknown OpenAI API: {api}")


# One instance per process: its HTTP connection pool is reused, so a request does not
# pay a new TLS connection to OpenAI (seconds on the first call)
@functools.cache
def get_llm_analysis_service() -> LLMService:
    """LLM service for async analysis (economico)."""
    if settings.llm_analysis_provider == "openai":
        return openai_llm(
            settings.llm_analysis_model,
            settings.llm_analysis_reasoning_effort,
            settings.llm_analysis_api,
        )
    raise ValueError(f"Unknown LLM provider: {settings.llm_analysis_provider}")


@functools.cache
def get_llm_query_service() -> LLMService:
    """LLM service for RAG queries (qualità)."""
    if settings.llm_query_provider == "openai":
        return openai_llm(
            settings.llm_query_model,
            settings.llm_query_reasoning_effort,
            settings.llm_query_api,
        )
    raise ValueError(f"Unknown LLM provider: {settings.llm_query_provider}")


@functools.cache
def get_llm_vision_service() -> LLMService:
    """LLM service that looks at photos from the wearable camera."""
    return openai_llm(
        settings.llm_vision_model,
        settings.llm_vision_reasoning_effort,
        settings.llm_vision_api,
    )


@functools.cache
def get_llm_intent_service() -> LLMService:
    """LLM service for the intent check (fast: it delays the answer)."""
    return openai_llm(
        settings.llm_intent_model,
        settings.llm_intent_reasoning_effort,
        settings.llm_intent_api,
    )
