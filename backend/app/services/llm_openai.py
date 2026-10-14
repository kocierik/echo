import json
from collections.abc import AsyncIterator

from openai import AsyncOpenAI

from app.core.config import settings
from app.services.llm_base import LLMMessage, LLMResponse, LLMService, LLMToolCall


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
    return {"role": m.role, "content": m.content}


def _parse_arguments(raw: str | None) -> dict:
    try:
        parsed = json.loads(raw or "{}")
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


class OpenAILLMService(LLMService):
    """OpenAI GPT LLM implementation."""

    def __init__(self, model: str):
        self.client = AsyncOpenAI(api_key=settings.openai_api_key)
        self.model = model

    async def complete(self, messages: list[LLMMessage], temperature: float = 0.3) -> LLMResponse:
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[{"role": m.role, "content": m.content} for m in messages],
            temperature=temperature,
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
            messages=[{"role": m.role, "content": m.content} for m in messages],
            temperature=temperature,
            stream=True,
        )
        async for chunk in chunks:
            if chunk.choices and (piece := chunk.choices[0].delta.content):
                yield piece

    async def complete_json(
        self, messages: list[LLMMessage], temperature: float = 0.1
    ) -> dict:
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[{"role": m.role, "content": m.content} for m in messages],
            temperature=temperature,
            response_format={"type": "json_object"},
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
            temperature=temperature,
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


def get_llm_analysis_service() -> LLMService:
    """LLM service for async analysis (economico)."""
    if settings.llm_analysis_provider == "openai":
        return OpenAILLMService(model=settings.llm_analysis_model)
    raise ValueError(f"Unknown LLM provider: {settings.llm_analysis_provider}")


def get_llm_query_service() -> LLMService:
    """LLM service for RAG queries (qualità)."""
    if settings.llm_query_provider == "openai":
        return OpenAILLMService(model=settings.llm_query_model)
    raise ValueError(f"Unknown LLM provider: {settings.llm_query_provider}")
