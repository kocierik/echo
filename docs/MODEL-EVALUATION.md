# Model evaluation

How Echo's models are chosen, and the latest results. Run the evaluations again before
changing a model in `.env`: they call the real APIs (a few cents per run).

```bash
make eval-llm MODEL=gpt-6-luna EFFORT=low SUITE=all              # every suite, chat completions
make eval-llm MODEL=gpt-6-luna EFFORT=low API=responses SUITE=tools
make eval-stt-collect                                          # save recent clips (audio lives 24 h)
make eval-stt PROVIDERS=deepgram:nova-3,openai:gpt-transcribe
```

- **compat**: the four calls Echo makes (completion with a temperature, JSON mode, tools,
  streaming). A model that fails one cannot replace the current one without code changes.
- **extraction**: entities from Italian sentences, `backend/evals/cases/extraction.json`
  (dates resolved from Wednesday 2026-10-14, vague wishes and "Echo, …" commands left out,
  known people kept as people).
- **routing**: the intent check of a chat request (memory, app, or "not connected"),
  `backend/evals/cases/routing.json`.
- **answers**: memory answers streamed from a given context, `backend/evals/cases/answers.json`:
  the answer holds the expected facts, uses the question's language, and says so when the
  memory has nothing. Reports the time to the first piece and to the whole answer.
- **tools**: the agent's first tool call against fake Composio tools plus `search_memory`,
  `backend/evals/cases/tools.json` (nothing is executed).
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

One run per model: directional, not statistical. Extraction has 14 cases, routing 10, answers 6,
tools 6.

| Model | Reasoning · API | compat | extraction | routing | answers | tools |
|---|---|---|---|---|---|---|
| `gpt-4o-mini` (analysis before) | — · chat | 4/4 | 10/14 · 1.1 s | 7/10 | | |
| `gpt-4o` (chat before) | — · chat | | | 9/10 → **10/10** | 6/6 · 1.5 s | 6/6 |
| `gpt-6-luna` | none · chat | 4/4 | 11/14 · 1.4 s | 7/10 → **10/10** · ~1 s | | |
| `gpt-6-luna` | low · chat | tools fail | **13/14** · 2.6 s | 9/10 → **10/10** · 3.0 s | | |
| `gpt-6-luna` | low · responses | 4/4 | | | 6/6 · 1.9 s | 6/6 |
| `gpt-6.1-sol` | low · responses | 4/4 | | | | |
| `gpt-5-nano` | minimal · chat | | | 9/10 · 0.9 s | | |
| `gpt-6-luna`, `gpt-6.1-sol` | (temperature) | 0/4 | | | | |

"→" is the same model after the routing prompt fix below. Answers: average time to the whole
answer; the first case of every run also pays for opening the connection.

Decisions (2026-10-14), now the defaults:
- **Analysis** (extraction, summaries, digest): `gpt-6-luna`, low reasoning, chat completions.
- **Chat answers and the actions agent**: `gpt-6-luna`, low reasoning, Responses API. Same
  results as `gpt-4o`, about 0.4 s slower per answer, at about a twentieth of the token price.
- **Intent check**: `gpt-6-luna` without reasoning (`none`), chat completions: it runs before
  every request, so it must be fast, and it reaches 10/10 at ~1 s.

Findings:
- The gpt-6 models reject any temperature but 1, so they need `LLM_*_REASONING_EFFORT` (no
  temperature is sent then). On chat completions function tools work only with `none`; the
  Responses API runs them with reasoning. `gpt-6.1-sol` has no `none`.
- Moving to the Responses API needed `openai` 2.x: the old `openai==1.51` pin was ours, not
  Composio's (`composio` 0.15–0.22 accept it).
- "Not connected" routing (Slack, Notion) failed with every model: the prompt now says that a
  request for an app that is not connected still names it, and Echo asks to connect it.
- Live latency of the intent check was 6–9 s because every request built a new OpenAI client
  and opened a new connection. The LLM and embedding services are now built once per process:
  a memory answer takes ~1.5 s end to end once warm. The first requests after a restart still
  pay for the connection.
- No STT comparison yet: the recordings on this server are older than the audio retention.
