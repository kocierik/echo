import base64
import functools
import json
import time
from collections.abc import AsyncIterator

from openai import AsyncOpenAI

from app.core.config import settings
from app.services.llm_base import LLMMessage, LLMResponse, LLMService, LLMToolCall
from app.services.usage import record_usage
from app.services.web_search import OpenAIWebSearch, citations_in, searches_in


def _chat_units(usage) -> tuple[int, int, int]:
    """(input, output, cached) tokens of a chat completion's usage."""
    if usage is None:
        return 0, 0, 0
    details = getattr(usage, "prompt_tokens_details", None)
    cached = getattr(details, "cached_tokens", None) or 0
    return (
        getattr(usage, "prompt_tokens", 0) or 0,
        getattr(usage, "completion_tokens", 0) or 0,
        cached,
    )


def _responses_units(usage) -> tuple[int, int, int]:
    """(input, output, cached) tokens of a Responses API usage."""
    if usage is None:
        return 0, 0, 0
    details = getattr(usage, "input_tokens_details", None)
    cached = getattr(details, "cached_tokens", None) or 0
    return (
        getattr(usage, "input_tokens", 0) or 0,
        getattr(usage, "output_tokens", 0) or 0,
        cached,
    )


def _elapsed_ms(started: float) -> int:
    """Milliseconds since `started` (time.monotonic()): the call's duration for its step."""
    return int((time.monotonic() - started) * 1000)


def _with_units(response: LLMResponse, units: tuple[int, int, int]) -> LLMResponse:
    response.input_tokens, response.output_tokens, response.cached_tokens = units
    return response


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
    kind = "llm_analysis"

    def __init__(self, model: str, reasoning_effort: str = "", kind: str = "llm_analysis"):
        self.client = AsyncOpenAI(api_key=settings.openai_api_key)
        self.model = model
        self.reasoning_effort = reasoning_effort
        # What the calls are recorded as (services/usage.py)
        self.kind = kind

    async def _record(self, units: tuple[int, int, int], started: float) -> None:
        await record_usage(
            self.kind, self.model,
            input_units=units[0], output_units=units[1], cached_units=units[2],
            duration_ms=_elapsed_ms(started),
        )

    def _sampling(self, temperature: float) -> dict:
        if self.reasoning_effort:
            # Not a named argument in the pinned SDK: sent as is
            return {"extra_body": {"reasoning_effort": self.reasoning_effort}}
        return {"temperature": temperature}

    async def complete(
        self, messages: list[LLMMessage], temperature: float = 0.3, hosted_tools=None
    ) -> LLMResponse:
        # Chat completions run no hosted tools (`can_search` is False): ignored
        started = time.monotonic()
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[_to_openai_message(m) for m in messages],
            **self._sampling(temperature),
        )
        choice = response.choices[0]
        units = _chat_units(response.usage)
        await self._record(units, started)
        return _with_units(LLMResponse(
            content=choice.message.content or "",
            model=response.model,
            usage_tokens=response.usage.total_tokens if response.usage else None,
        ), units)

    async def stream(
        self,
        messages: list[LLMMessage],
        temperature: float = 0.3,
        hosted_tools=None,
        on_citations=None,
    ) -> AsyncIterator[str]:
        started = time.monotonic()
        chunks = await self.client.chat.completions.create(
            model=self.model,
            messages=[_to_openai_message(m) for m in messages],
            stream=True,
            # The last chunk then carries the usage
            stream_options={"include_usage": True},
            **self._sampling(temperature),
        )
        units = None
        async for chunk in chunks:
            if getattr(chunk, "usage", None) is not None:
                units = _chat_units(chunk.usage)
            if chunk.choices and (piece := chunk.choices[0].delta.content):
                yield piece
        if units is not None:
            await self._record(units, started)

    async def complete_json(
        self, messages: list[LLMMessage], temperature: float = 0.1
    ) -> dict:
        started = time.monotonic()
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[_to_openai_message(m) for m in messages],
            response_format={"type": "json_object"},
            **self._sampling(temperature),
        )
        await self._record(_chat_units(response.usage), started)
        content = response.choices[0].message.content or "{}"
        return json.loads(content)

    async def complete_with_tools(
        self,
        messages: list[LLMMessage],
        tools: list[dict],
        temperature: float = 0.2,
        hosted_tools=None,
    ) -> LLMResponse:
        started = time.monotonic()
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[_to_openai_message(m) for m in messages],
            tools=tools,
            tool_choice="auto",
            **self._sampling(temperature),
        )
        message = response.choices[0].message
        units = _chat_units(response.usage)
        await self._record(units, started)
        return _with_units(LLMResponse(
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
        ), units)


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
    translated to Responses items. Hosted tools (web search) run here only.
    """

    kind = "llm_analysis"
    can_search = True

    def __init__(self, model: str, reasoning_effort: str = "", kind: str = "llm_analysis"):
        self.client = AsyncOpenAI(api_key=settings.openai_api_key)
        self.model = model
        self.reasoning_effort = reasoning_effort
        # What the calls are recorded as (services/usage.py)
        self.kind = kind

    async def _record(self, units: tuple[int, int, int], started: float) -> None:
        await record_usage(
            self.kind, self.model,
            input_units=units[0], output_units=units[1], cached_units=units[2],
            duration_ms=_elapsed_ms(started),
        )

    def _options(self, temperature: float) -> dict:
        if self.reasoning_effort:
            return {"reasoning": {"effort": self.reasoning_effort}}
        return {"temperature": temperature}

    async def _record_searches(self, output) -> list[dict]:
        """Counts the searches the model ran; returns the pages the answer cites."""
        if count := searches_in(output):
            await record_usage("web_search", OpenAIWebSearch.usage_model, input_units=count)
        return citations_in(output)

    async def complete(
        self, messages: list[LLMMessage], temperature: float = 0.3, hosted_tools=None
    ) -> LLMResponse:
        tools = {"tools": list(hosted_tools)} if hosted_tools else {}
        started = time.monotonic()
        response = await self.client.responses.create(
            model=self.model,
            input=_to_response_items(messages),
            **tools,
            **self._options(temperature),
        )
        units = _responses_units(response.usage)
        await self._record(units, started)
        citations = await self._record_searches(getattr(response, "output", None))
        return _with_units(LLMResponse(
            content=response.output_text or "",
            model=response.model,
            usage_tokens=response.usage.total_tokens if response.usage else None,
            citations=citations,
        ), units)

    async def stream(
        self,
        messages: list[LLMMessage],
        temperature: float = 0.3,
        hosted_tools=None,
        on_citations=None,
    ) -> AsyncIterator[str]:
        """The answer in pieces; with a search, the stream pauses while it runs, and
        `on_citations` gets the cited pages once the answer is complete."""
        tools = {"tools": list(hosted_tools)} if hosted_tools else {}
        started = time.monotonic()
        events = await self.client.responses.create(
            model=self.model,
            input=_to_response_items(messages),
            stream=True,
            **tools,
            **self._options(temperature),
        )
        async for event in events:
            if event.type == "response.output_text.delta" and event.delta:
                yield event.delta
            elif event.type == "response.completed":
                response = getattr(event, "response", None)
                await self._record(_responses_units(getattr(response, "usage", None)), started)
                citations = await self._record_searches(getattr(response, "output", None))
                if on_citations is not None and citations:
                    on_citations(citations)

    async def complete_json(
        self, messages: list[LLMMessage], temperature: float = 0.1
    ) -> dict:
        started = time.monotonic()
        response = await self.client.responses.create(
            model=self.model,
            input=_to_response_items(messages),
            text={"format": {"type": "json_object"}},
            **self._options(temperature),
        )
        await self._record(_responses_units(response.usage), started)
        return json.loads(response.output_text or "{}")

    async def complete_with_tools(
        self,
        messages: list[LLMMessage],
        tools: list[dict],
        temperature: float = 0.2,
        hosted_tools=None,
    ) -> LLMResponse:
        started = time.monotonic()
        response = await self.client.responses.create(
            model=self.model,
            input=_to_response_items(messages),
            tools=[_to_response_tool(tool) for tool in tools] + list(hosted_tools or []),
            tool_choice="auto",
            **self._options(temperature),
        )
        units = _responses_units(response.usage)
        await self._record(units, started)
        citations = await self._record_searches(response.output)
        return _with_units(LLMResponse(
            content=response.output_text or "",
            model=response.model,
            usage_tokens=response.usage.total_tokens if response.usage else None,
            citations=citations,
            tool_calls=[
                LLMToolCall(
                    id=item.call_id, name=item.name, arguments=_parse_arguments(item.arguments)
                )
                for item in response.output
                if item.type == "function_call"
            ],
        ), units)


def openai_llm(
    model: str, reasoning_effort: str = "", api: str = "chat", kind: str = "llm_analysis"
) -> LLMService:
    """The OpenAI service for an `api` of "chat" (chat completions) or "responses";
    `kind` is what its calls are recorded as (services/usage.py)."""
    if api == "responses":
        return OpenAIResponsesLLMService(model, reasoning_effort, kind)
    if api == "chat":
        return OpenAILLMService(model, reasoning_effort, kind)
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
            kind="llm_analysis",
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
            kind="llm_query",
        )
    raise ValueError(f"Unknown LLM provider: {settings.llm_query_provider}")


@functools.cache
def get_llm_vision_service() -> LLMService:
    """LLM service that looks at photos from the wearable camera."""
    return openai_llm(
        settings.llm_vision_model,
        settings.llm_vision_reasoning_effort,
        settings.llm_vision_api,
        kind="llm_vision",
    )


@functools.cache
def get_llm_intent_service() -> LLMService:
    """LLM service for the intent check (fast: it delays the answer)."""
    return openai_llm(
        settings.llm_intent_model,
        settings.llm_intent_reasoning_effort,
        settings.llm_intent_api,
        kind="llm_intent",
    )
