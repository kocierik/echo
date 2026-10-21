# Web search and routines — Design

Date: 2026-10-21. Status: discussed with the user in chat; to be approved before a plan is written.
Roadmap: Fase 7, "Incarichi ricorrenti", and the idea "ricerca web nella chat".

## Intent

Two things Echo cannot do today, and that the user wants together:

- **Look things up.** Echo has no live information: since 16/10 it says "Echo cannot see live
  information" for the weather, news, scores or today's prices instead of inventing them. The user
  wants it to search online.
- **Do something on its own at a time.** Nothing user-defined ever runs on a schedule: the server's
  timed jobs (digest, summaries, retention) are the same for everyone. The user wants things like
  "every morning at 7 tell me the weather", delivered as a **notification on the phone**.

The second needs the first for anything live, so they are designed together. Echo is a hosted,
sold service: every search costs money and is counted per user.

## Goals

1. **Web search** in chat (Ask), in voice requests ("Ehi Echo, che tempo fa domani a Milano?") and
   in routines, used by the model only when the question needs live information, with the sources
   it used.
2. **Routines** ("incarichi ricorrenti"): created by asking, in Ask or by voice ("Ehi Echo, ogni
   mattina alle 7 dimmi che tempo fa a Milano"); run by the server at their time in the user's time
   zone; the answer arrives as a notification and in the chat.
3. **Seen and controlled** in Settings → Routines: what, when, next run, last result; pause, resume,
   delete.
4. **Costs counted and capped:** every search recorded per user (`llm_usage`), a daily cap per user.
5. **Replaceable search provider:** OpenAI's built-in search first; the user plans to move to
   Perplexity later, so the provider sits behind one small interface.

## Non-goals (for now)

- Routines that **act on other people** (send a message, change an event): unattended, nothing can
  wait for the user's Confirm. Routines read (web, memory, connected apps) and tell the user. A
  routine that creates something for the user alone (a reminder, a task) is a later step.
- Event rules ("when I promise something to a client…"): a separate roadmap item.
- Push notifications when the app is not running: they need the paid Apple developer account (APNs).
- A dedicated weather service: web search covers it at first (roadmap: cheaper and steadier later).
- Perplexity: later, behind the same interface.

## Anti-goals

- A routine running more often than every hour, or a search loop that spends without limit.
- Searches nobody can see or stop: every routine is listed with a pause and a delete.
- Search results presented as the user's memory: the answer says what came from the web, with links.
- A routine's answer that invents weather, news or prices when the search fails or the cap is
  reached: it says it could not look it up.

## What the user decided (in chat, 21/10)

- Results of routines as a **notification on the phone**.
- **OpenAI's web search** first, counted and capped per user; **Perplexity later** ("vedremo di migrare
  a perplexity in futuro").
- Search costs compared on 21/10 (aggregators, to verify): OpenAI ~10 $ / 1,000 searches plus tokens;
  Brave and Perplexity Search ~5 $; Tavily ~8 $. About 1.80 $ a month for an active user at 5
  searches a day plus a daily routine: small next to transcription.
- The assistant is called with a greeting ("Ehi Echo"): done on 21/10 (`e83b848`).

## Part A — Web search

**How the model searches.** The memory answer (`routers/query.py`, `services/memory_answers.py`), the
voice requests' memory answer (`workers/voice_requests.py`) and the action agent
(`actions/agent.py`) already call the query model through the Responses API (`LLM_QUERY_API=responses`).
They get one more tool, the provider's search, offered only while the user is under the daily cap.
The model decides when to use it; the prompt's fourth kind of question ("live information") changes
from "say you cannot see it" to "search, and say what the web says, with the sources". When the tool
is not offered (cap reached, provider down, `WEB_SEARCH_PROVIDER=none`), the old rule stays.

**The interface.** `services/web_search.py`:

- `WebSearchProvider` with `tool_definition() -> dict` (what the model is offered) and
  `searches_in(response) -> int` (how many it ran, to count them), plus `sources_in(response)` (title
  and URL of each source the model cited).
- `OpenAIWebSearch`: the Responses API's built-in web search tool (name and options as the pinned
  `openai` SDK spells them; the builder checks). Perplexity later implements the same three.
- Setting `WEB_SEARCH_PROVIDER` = `openai` (default) or `none`.

**Counting and the cap.** Each search adds a row to `llm_usage` with kind `web_search`, model the
provider's name, `input_units` = searches. `WEB_SEARCHES_PER_DAY` (default 30) per user per UTC day,
read from `llm_usage` before offering the tool. `usage_prices.py` gains a per-search price
(`{"unit": "search", "per_search": 0.010}` for OpenAI, marked unverified like the others) and
`make usage` shows searches with the rest.

**What the user sees.** In Ask, the answer's sources show web links (title, domain) next to the
memory sources, opening in the browser. In voice answers, the text names the source ("secondo
ilmeteo.it…"). Answers from the web are never written into the memory (no entities, no chunks).

## Part B — Routines

**Model.** Table `routines`: `id`, `user_id`, `instruction` (the request in the user's words, e.g.
"dimmi che tempo fa a Milano"), `schedule` (structured: `kind` = `daily` | `weekdays` | `weekly` |
`monthly`, `time` "07:00", `days` [1–7] for weekly, `day_of_month` for monthly), `timezone` (the
user's at creation, `USER_TIMEZONE` today), `active`, `next_run_at` (UTC), `last_run_at`,
`last_status` (`ok` | `failed` | `skipped`), `last_answer` (text), `created_at`, and `source`
(`chat` | `voice`). At most 10 routines per user.

**Creating.** The action agent gets three tools (always offered, no app connection needed, CREATE
tier: they only concern the user): `create_routine(instruction, schedule)`, `list_routines()`,
`delete_routine(id)`. The intent check routes "ogni mattina alle 7…", "every Friday…", "stop the
morning weather" to the agent. The agent turns the spoken time into the structured schedule; when the
place or the time is missing ("dimmi il meteo ogni mattina"), it asks ("A che ora, e per quale
città?") instead of guessing. It confirms in words: "Ogni mattina alle 7:00 ti dirò che tempo fa a
Milano. Puoi fermarlo in Settings → Routines."

**Running.** A worker loop (`workers/routines.py`, like the digest loop) every minute claims the
routines due (`active` and `next_run_at <= now`) with `FOR UPDATE SKIP LOCKED`, so two workers never
run one twice, and for each:

1. runs the instruction through the action agent as the routine's user (`owned_by`), with the
   memory, the read tools of the connected apps, web search, and **no tool of the confirm tier**
   (nothing waits for a Confirm that no one is there to give);
2. appends the instruction and the answer to a chat session named **"Routines"** (like "Voice
   requests": one per user, pinned);
3. tells the phone: a device command `voice_update` on the queue the app already long-polls;
4. sets `last_*` and the next `next_run_at` from the schedule in the routine's time zone (a missed
   run, the server down at 7:00, runs once when it is back if within 2 hours, else is skipped and
   marked `skipped`).

A run is limited like a chat request (the agent's step limit, a 60 s timeout). A failure is logged
in `last_status` and the action log, and the notification says "Your 7:00 routine could not run."

**The notification on the phone.** The app's command loop handles `voice_update` by running the
voice-updates check it already has, which shows the notification and opens the chat on a tap. The
check learns the "Routines" session next to "Voice requests". Honest limit, said in Settings: the
notification arrives at its time **while the app is running** (in the foreground, or in the
background connected to the wearable); otherwise when the app next opens. On Android the foreground
service keeps it running while paired.

**Settings → Routines (app).** The list: instruction, schedule in words ("Every day at 7:00",
"Weekdays at 8:30"), next run, last result (text, or "Could not run"); a switch to pause; swipe or a
button to delete. English copy. A short line: "Ask Echo to set one up: 'Hey Echo, every morning at 7
tell me the weather in Milan.'" No form to create one in Settings (asking is the way), and "What Echo
can do" gains that example.

**REST.** `GET /api/routines`, `PATCH /api/routines/{id}` (`{active}`), `DELETE /api/routines/{id}`;
creation goes through the agent only. The MCP server is not changed.

## Order of work

1. Part A, web search in Ask and voice (useful at once), with counting and the cap.
2. Routines: table and REST, then the agent's tools, then the worker loop, then the phone's
   notification, then Settings → Routines.

## Constraints

- Python 3.11, FastAPI 0.115, SQLAlchemy async, Alembic (next migration 020); Flutter for iOS and
  Android, English UI copy; the AI answers in the user's language.
- Times are stored in UTC; schedules are read in the routine's time zone (DST-safe: 7:00 stays 7:00).
- Tests one suite at a time; TDD; commit to main and push when verified.

## Calls made by Claude (check these)

- Search is a tool the model may call, not a separate route: no extra call for normal questions.
- Routines cannot use confirm-tier tools; creating reminders or tasks from a routine comes later.
- Routines are created by asking only; Settings lists, pauses and deletes.
- At most 10 routines per user; no schedule more frequent than daily (hourly would need a cap of its
  own).
- 30 searches per user per day by default.
- A missed run catches up once within 2 hours, else it is skipped.
- Answers from the web never go into the memory.
- Routine answers live in a pinned "Routines" chat, separate from "Voice requests".

## Left to the builder

- The exact name and options of OpenAI's web search tool in the pinned SDK, and how searches and
  cited sources appear in a Responses result (to count and to show them).
- How to stream an Ask answer when the model searches mid-answer (the search may pause the stream).
- The words of the agent's prompt for creating routines, and the schedule parsing cases in the evals.
