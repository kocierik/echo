import json

from openai import AsyncOpenAI

from app.core.config import settings
from app.services.llm_base import LLMMessage, LLMResponse, LLMService


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
