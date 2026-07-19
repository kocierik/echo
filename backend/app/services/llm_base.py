from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class LLMMessage:
    role: str  # "system" | "user" | "assistant"
    content: str


@dataclass
class LLMResponse:
    content: str
    model: str
    usage_tokens: int | None = None


class LLMService(ABC):
    """Abstract interface for Large Language Model services."""

    @abstractmethod
    async def complete(self, messages: list[LLMMessage], temperature: float = 0.3) -> LLMResponse:
        """Generate a completion from a list of messages.

        Args:
            messages: Conversation messages.
            temperature: Sampling temperature (0 = deterministic).

        Returns:
            LLMResponse with generated text.
        """
        ...

    @abstractmethod
    async def complete_json(
        self, messages: list[LLMMessage], temperature: float = 0.1
    ) -> dict:
        """Generate a JSON-structured completion.

        Args:
            messages: Conversation messages (system prompt should request JSON output).
            temperature: Sampling temperature.

        Returns:
            Parsed JSON dict.
        """
        ...
