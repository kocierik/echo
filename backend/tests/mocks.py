"""Mock implementations of AI services for testing without API keys."""

import hashlib
import struct

from app.services.embedding_base import EmbeddingService
from app.services.llm_base import LLMMessage, LLMResponse, LLMService


class MockEmbeddingService(EmbeddingService):
    """Deterministic mock embedding service.

    Generates consistent 1536-dimension vectors from text content using
    a hash-based approach. Semantically similar texts won't produce similar
    vectors, but identical texts will produce identical vectors.
    """

    def __init__(self, dimensions: int = 1536):
        self.dimensions = dimensions

    async def embed(self, text: str) -> list[float]:
        return self._generate_embedding(text)

    async def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [self._generate_embedding(t) for t in texts]

    def _generate_embedding(self, text: str) -> list[float]:
        """Generate a deterministic pseudo-embedding from text hash."""
        # Use SHA-512 repeatedly to fill 1536 dimensions
        result = []
        seed = text.encode()
        while len(result) < self.dimensions:
            seed = hashlib.sha512(seed).digest()
            # Unpack 8 doubles from 64 bytes
            floats = struct.unpack("8d", seed)
            # Normalize to [-1, 1] range
            result.extend(f / (abs(f) + 1.0) for f in floats)
        return result[: self.dimensions]


class MockLLMService(LLMService):
    """Mock LLM service that returns canned responses.

    Useful for testing the RAG pipeline without making API calls.
    """

    def __init__(self, default_response: str = "Risposta di test dal mock LLM."):
        self.default_response = default_response
        self.call_log: list[list[LLMMessage]] = []

    async def complete(self, messages: list[LLMMessage], temperature: float = 0.3) -> LLMResponse:
        self.call_log.append(messages)
        # Extract a relevant answer from context if available
        user_msg = next((m.content for m in reversed(messages) if m.role == "user"), "")
        if "Contesto dalla memoria:" in user_msg:
            return LLMResponse(
                content="Basandomi sulla memoria, ecco cosa ho trovato nel contesto fornito.",
                model="mock-gpt-4o",
                usage_tokens=50,
            )
        return LLMResponse(
            content=self.default_response,
            model="mock-gpt-4o",
            usage_tokens=20,
        )

    async def complete_json(self, messages: list[LLMMessage], temperature: float = 0.1) -> dict:
        self.call_log.append(messages)
        # Check what kind of JSON is expected based on system prompt
        system_msg = next((m.content for m in messages if m.role == "system"), "")
        if "entities" in system_msg.lower():
            return {
                "entities": [
                    {
                        "type": "person",
                        "name": "Marco",
                        "content": "Persona menzionata nel test",
                        "metadata": {"role": "collega"},
                    }
                ]
            }
        if "title" in system_msg.lower() and "summary" in system_msg.lower():
            return {
                "title": "Conversazione di test",
                "summary": "Riassunto della conversazione di test.",
            }
        return {}
