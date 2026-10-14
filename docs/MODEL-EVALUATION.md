# Model evaluation

How Echo's models are chosen, and the latest results. Run the evaluations again before
changing a model in `.env`: they call the real APIs (a few cents per run).

```bash
make eval-llm MODEL=gpt-6-luna EFFORT=none SUITE=all   # compat, extraction, routing
make eval-stt-collect                                  # save recent clips (audio lives 24 h)
make eval-stt PROVIDERS=deepgram:nova-3,openai:gpt-transcribe
```

- **compat**: the four calls Echo makes (completion with a temperature, JSON mode, tools,
  streaming). A model that fails one cannot replace the current one without code changes.
- **extraction**: entities from Italian sentences, `backend/evals/cases/extraction.json`
  (dates resolved from Wednesday 2026-10-14, vague wishes and "Echo, …" commands left out,
  known people kept as people).
- **routing**: the intent check of a chat request (memory, app, or "not connected"),
  `backend/evals/cases/routing.json`.
- **stt**: word error rate of each service on clips saved from your own use, against
  references you correct by hand in `backend/evals/data/stt/*.ref.txt` (git-ignored). A
  correction made in the app becomes a verified reference. Completed audio is deleted after
  `COMPLETED_AUDIO_RETENTION_HOURS` (24): collect within a day of recording.

## Deadlines (OpenAI deprecations page, 2026-10-14)

| Model | Used for | Shut down | Replacement |
|---|---|---|---|
| `gpt-4o`, `gpt-4o-mini` | every LLM call | 2027-01-14 | `gpt-6-luna` |
| `gpt-4o-transcribe` | STT when `STT_PROVIDER=openai` | 2027-02-26 | `gpt-transcribe` |

## Results, 2026-10-14

One run per model on 14 extraction and 10 routing cases: directional, not statistical.

| Model | Reasoning | compat | extraction | routing | Notes |
|---|---|---|---|---|---|
| `gpt-4o-mini` (analysis today) | — | 4/4 | 10/14 · 1.1 s | 7/10 | drops known people mentioned in a task or event |
| `gpt-4o` (chat today) | — | — | — | 9/10 | |
| `gpt-6-luna` | none | 4/4 | 11/14 · 1.4 s | 7/10 | the only setting where tools work on chat completions |
| `gpt-6-luna` | low | tools fail | **13/14** · 2.6 s | **9/10** · 3.0 s | tools need the Responses API |
| `gpt-6-luna`, `gpt-6.1-sol` | (temperature) | 0/4 | — | — | reject any temperature but 1 |
| `gpt-6.1-sol` | low | tools fail | — | — | no "none" effort: tools only on the Responses API |

Findings:
- The gpt-6 models need `LLM_*_REASONING_EFFORT` (no temperature is sent then). With chat
  completions, function tools work only with `none`, so the action agent cannot use reasoning
  until it moves to the Responses API (the pinned `openai==1.51` predates it; `composio==0.15`
  pins it).
- `gpt-6-luna` with low reasoning extracts best and routes like `gpt-4o`, at a lower token
  price than `gpt-4o-mini` (reasoning tokens add some output; latency does not matter in the
  worker).
- "Not connected" routing (Slack, Notion) fails with every model: the intent check, not the
  model, needs work.
- No STT comparison yet: the recordings on this server are older than the audio retention.
