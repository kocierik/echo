# Provider abstraction for all AI services

All AI services (STT, LLM, Embeddings) are accessed through abstract interfaces. Concrete implementations wrap specific providers (OpenAI Whisper, GPT-4o-mini, text-embedding-3-small for MVP). Swapping providers requires only a new implementation of the interface, no changes to business logic.

## Considered Options

- **Direct SDK calls throughout the codebase**: Faster to write initially but creates vendor lock-in. Changing provider requires touching every call site.
- **Single-provider assumption with "refactor later"**: Risky given the project's explicit goal of provider flexibility.

## Consequences

- Slightly more code upfront (interface + implementation per service).
- Enables the project's stated goal of supporting OpenAI, Anthropic, Gemini, and open-source models without architectural change.
- Testing is easier: mock the interface rather than the SDK.
