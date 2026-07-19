# Structured entities plus vector search for Memory

Memory combines two retrieval strategies: (1) vector similarity search via pgvector over Transcription embeddings for natural language Queries, and (2) structured Entity records (people, tasks, ideas, events) extracted by LLM Analysis, stored relationally in PostgreSQL. Recall uses both: vector search finds relevant Transcriptions, Entity metadata enables filtering and linking.

## Considered Options

- **Flat documents + vector search only**: Simpler but no way to filter by entity type, person, or date range without semantic ambiguity.
- **Knowledge graph (nodes + edges)**: Maximum expressivity for connecting concepts across time, but introduces graph database complexity (additional infrastructure, query language) disproportionate to MVP needs.

## Consequences

- PostgreSQL serves both roles (relational entities + pgvector), keeping infrastructure simple.
- The Entity schema will evolve as we discover what the LLM reliably extracts. Start minimal (type, name, source_transcription, timestamp).
- A knowledge graph can be layered on top later if relationship traversal becomes a core need.
