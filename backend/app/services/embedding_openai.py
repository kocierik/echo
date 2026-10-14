import functools

from openai import AsyncOpenAI

from app.core.config import settings
from app.services.embedding_base import EmbeddingService


class OpenAIEmbeddingService(EmbeddingService):
    """OpenAI text-embedding implementation."""

    def __init__(self):
        self.client = AsyncOpenAI(api_key=settings.openai_api_key)
        self.model = settings.embedding_model

    async def embed(self, text: str) -> list[float]:
        response = await self.client.embeddings.create(
            model=self.model,
            input=text,
        )
        return response.data[0].embedding

    async def embed_batch(self, texts: list[str]) -> list[list[float]]:
        response = await self.client.embeddings.create(
            model=self.model,
            input=texts,
        )
        return [item.embedding for item in response.data]


# One instance per process: its HTTP connection pool is reused, so a request does not
# pay a new TLS connection to OpenAI (seconds on the first call)
@functools.cache
def get_embedding_service() -> EmbeddingService:
    """Factory function to get the configured embedding service."""
    if settings.embedding_provider == "openai":
        return OpenAIEmbeddingService()
    raise ValueError(f"Unknown embedding provider: {settings.embedding_provider}")
