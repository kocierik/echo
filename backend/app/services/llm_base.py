from abc import ABC, abstractmethod
from dataclasses import dataclass, field


@dataclass
class LLMToolCall:
    id: str
    name: str
    arguments: dict


@dataclass
class LLMMessage:
    role: str  # "system" | "user" | "assistant" | "tool"
    content: str
    tool_calls: list[LLMToolCall] | None = None  # assistant messages only
    tool_call_id: str | None = None  # tool messages only
    name: str | None = None


@dataclass
class LLMResponse:
    content: str
    model: str
    usage_tokens: int | None = None
    tool_calls: list[LLMToolCall] = field(default_factory=list)


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

    @abstractmethod
    async def complete_with_tools(
        self, messages: list[LLMMessage], tools: list[dict], temperature: float = 0.2
    ) -> LLMResponse:
        """Generate a completion that may request tool calls.

        Args:
            messages: Conversation messages, including assistant tool calls and tool results.
            tools: Tool definitions in OpenAI function-calling format.
            temperature: Sampling temperature.

        Returns:
            LLMResponse whose tool_calls lists the tools the model wants to run.
        """
        ...
