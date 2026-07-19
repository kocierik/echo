# Store-then-analyze: immediate persistence with async LLM analysis

Transcriptions are persisted immediately upon completion of STT. A background job then performs LLM-based Analysis to extract Entities (people, tasks, ideas, events) and group Segments into Conversations. The user-facing API never blocks on LLM processing.

## Considered Options

- **Synchronous LLM analysis**: Simpler flow but adds seconds of latency to the ingest pipeline. If the LLM fails or is slow, audio processing stalls.
- **Save only, no analysis**: Loses the structured Entity extraction that makes Memory queryable beyond raw text search.

## Consequences

- Audio ingest is resilient: STT failure and LLM failure are independent. Raw Transcriptions are never lost even if Analysis fails.
- Entities may lag a few seconds behind Transcriptions. The web UI should handle "not yet analyzed" gracefully.
- Batch re-analysis is trivial: improve prompts or switch LLM, re-run Analysis on existing Transcriptions.
