# Routines that speak only when needed — design

Date: 2026-10-28. Status: approved in conversation, to be planned.

## Why

Routines exist (22/10): "every morning at 7 tell me the weather in Milan" runs on the server
and its answer lands in the user's thread with Echo, with a notification. Real use showed
three problems:

1. **Every routine always speaks.** The user's actual routines are of three kinds:
   - "show me the weather every day": always worth an answer;
   - "tell me if it rains": only worth a word when it rains;
   - "check for new job openings": only worth a word when there is something *new*. Today
     Echo also has no memory of what it found last time, so the same openings would come
     back every day.
2. **Routine answers clutter the chat.** Each run writes the instruction into the thread as
   if the user had just said it, every morning, then the answer.
3. **Answers are cut.** Profile → Routines shows the last answer in two lines with an
   ellipsis and nothing opens it; the user could not read a weather answer in full.

The user wants routines that stay quiet when there is nothing to say, a place to see
their results apart from the chat, today's results on Today, and every text readable in
full.

## Goals

- A routine has a **mode**, picked by the agent from how the user phrases it:
  - `always` — every run reports (today's behaviour);
  - `only_if` — the run reports only when the condition in the instruction holds
    ("dimmi se piove");
  - `only_new` — the run reports only items not reported before by this routine
    ("nuove posizioni di lavoro").
- A run that has nothing to say produces **no notification and nothing on Today's main
  rows**, but it is recorded, so the user can tell a quiet routine from a broken one.
- Each run is **its own record** (a routine run): one source for Today, Ask → Routines,
  Profile → Routines and the "already seen" memory of `only_new`.
- **Today** gets a "From your routines" panel (mockup A, chosen 28/10) above "To do today",
  only when a routine ran today.
- **Ask** gets a switch at the top, **Chat | Routines**. Routines is the history of runs,
  by day; routine answers no longer go into the chat thread.
- From a routine result, **"Ask about this"** opens the Chat with that result as the
  context of the next question, so "e domani?" still works (approved 28/10).
- **No text is cut without a way to read it in full** (the user's rule for the whole app;
  the app-wide sweep is a separate change done before this one, see "Related").

## Non-goals (for now)

- Push notifications with the app closed (APNs): the user does not pay for the Apple
  developer account yet. Notifications keep arriving when the app wakes or opens, as today;
  when APNs comes, the same runs drive the push.
- Routines that create tasks or reminders, "pause all routines", durable runs that resume
  after a restart, routines more often than once a day.
- Changing a routine's mode from the UI: it is set when the routine is created (by voice or
  in Ask); to change it the user asks Echo again. *(Builder's call allowed: an edit action
  later.)*
- Dedicated job-site integrations (LinkedIn, Indeed APIs): `only_new` uses the tools
  routines already have (web search, connected apps, memory).

## Anti-goals (a failure even if it works)

- A routine that fails **looks like** a routine with nothing to say. Failures must stay
  visible (red line in Today's panel, in Ask → Routines and in Profile → Routines).
- An unparseable run result treated as "nothing to say": when in doubt, **report**.
- The same job opening reported on two days.
- More notifications than today: quiet runs never notify.
- Routine runs mixed back into the user's chat.
- Any routine text ending in "…" with no way to open it.

## Constraints

- Server: FastAPI + Postgres; next migration is **026** (after `025_user_plan`).
- Runs go through the action agent as today (`workers/routines.py`, `run_action_agent`,
  `source="routine"`, no confirm tools, no routine tools), with `RUN_TIMEOUT_S = 60`.
  Web searches count against the user's daily search budget as today.
- Plans limit how many routines a user has (`services/plans.py`); unchanged.
- The phone learns about new answers by polling when it wakes (`voice_updates_service.dart`,
  nudged by the `voice_update` device command). No APNs.
- App strings are in English; routine texts are in the user's language (as answers are).
- Tests: pytest (backend, Docker, `make test-all`) and `flutter test`; both must pass.
- One user today (confirmed 28/10): server and app are updated together, with no
  transition for older app builds (the server can stop writing routine runs to the thread
  in the same release).

## How it works (decided)

### Data

- `routines.mode`: `always` | `only_if` | `only_new`, default `always` (existing routines
  keep today's behaviour).
- New table `routine_runs`, one row per run:
  - `id`, `routine_id` (deleted with its routine), `user_id`, `ran_at`;
  - `status`: `reported` (has something to say) | `nothing` (quiet run of an `only_if` /
    `only_new` routine) | `failed` | `skipped` (missed while the server was down);
  - `text` (the answer, in full; null for `nothing` and `skipped`);
  - `sources` (the web pages cited, same shape as today's `citations`);
  - `items` (`only_new` only): the items reported in this run, each with a stable `key`
    (the link when there is one, else a normalized title) plus `title` and `url`.
- `routines.last_status` / `last_answer` stay, updated from the latest run (`ok` becomes
  `reported`; `nothing` added), so Profile → Routines keeps working.

### Creating a routine

- `ECHO_CREATE_ROUTINE` gains a `mode` parameter. Its description tells the model how to
  pick it: a condition ("se piove", "if it's below zero") → `only_if`; "new", "nuove",
  "se ci sono novità" → `only_new`; otherwise `always`. The instruction keeps the user's
  words (with the condition), as today.
- The agent's confirmation to the user says the mode in plain words ("Ti scrivo solo se
  piove").
- `ECHO_LIST_ROUTINES` includes the mode.

### Running a routine

- `always`: as today; the run is `reported`.
- `only_if` / `only_new`: the run asks the agent for a **structured result**: whether there
  is something to report, the text, and for `only_new` the items with their keys. For
  `only_new` the prompt includes the keys and titles already reported by this routine
  (from its runs, most recent first, capped), and the server **also** drops any returned
  item whose key was already reported, then reports only if items remain.
- *(Designer's call, 28/10.)* For `only_new` the structured result carries **one short line
  per item** (title, a few words, link) and an optional one-line intro. The text shown to
  the user is **built by the server from the items that remain** after the filter (the
  intro, then one line per item), so a filtered-out item never appears in the text. No
  second model call.
- *(Designer's call, 28/10.)* A result that cannot be read as structured is retried once
  with a stricter instruction; if it still cannot be read, it is stored as `reported` with
  the raw text, for every mode. A rare repeated item is a smaller harm than a routine that
  silently stops working. A timeout or error is `failed`, as today.
- *(Designer's call, 28/10.)* A `skipped` run (missed while the server was down) is shown
  as one muted line ("Missed at 7:00: Echo's server was off") in Today, Ask → Routines and
  Profile; it is **not** counted in "N checked, nothing new" and does not notify.
- Nothing is written to the chat thread any more. Existing routine messages already in the
  thread stay where they are.
- After a `reported` or `failed` run the phone is nudged as today (`voice_update`); after a
  `nothing` run it is not.

### API

- `GET /api/routines` includes `mode`.
- `GET /api/routine-runs`: the user's runs, newest first, paginated; filters by
  `routine_id` and by day (Today asks for today's runs in the user's time zone). Each run
  carries its routine's instruction and mode so the app needs no second call.
- "Ask about this" *(designer's call, 28/10)*: the app opens the **thread with Echo** (the
  chat Ask opens by default) and the server adds the run to that thread's history as an
  assistant message tagged with its routine and run (the result as the user saw it, with
  its sources). The user's next question then has it in the history, so routing
  (`might_need_tools` / `route_request` look at the history) can send "e domani?" to the
  agent with web search, and a reload still shows what the question was about. The run is
  added once (a second "Ask about this" on the same run does not duplicate it). This is the
  only way a routine result enters the chat: by the user's choice.

### Phone: notifications

- The phone's update check also looks for new `reported` and `failed` runs and shows one
  local notification per run, as routine answers do today; tapping it opens the run's full
  text. Quiet runs never notify.

### Today: "From your routines" (mockup A)

- A panel above "To do today", shown only when a routine ran today.
- One row per `reported` or `failed` run of today: the start of the text, below it the
  mode in words and the time ("If it rains · 7:00"). `failed` rows say "Could not run" in
  the error colour.
- Quiet runs are one muted line at the bottom: "2 checked, nothing new".
- **Tapping a row opens the full text** in a sheet: the routine's instruction and time,
  the whole answer, its sources as links, and "Ask about this".
- Results of earlier days are not on Today; they are in Ask → Routines.

### Ask: Chat | Routines

- A two-way switch at the top of Ask. Chat is today's Ask, unchanged.
- Routines: the runs grouped by day, newest first, each with its routine's instruction,
  time, **full text** (no cut) and sources; `nothing` runs as one muted line; `failed` in
  the error colour. A row of chips at the top filters by routine. Each result has "Ask
  about this".
- "Ask about this" switches to Chat, where the result now appears as the last message of
  the thread (see API), with the composer focused.

### Profile → Routines

- Each routine shows its mode in words.
- The last result opens in full on tap (the same sheet as Today), and a "See all results"
  opens Ask → Routines filtered on that routine.

## Left to the builder

- How the structured result is obtained from the agent (a final tool call, a JSON answer,
  or a second small call), as long as it is deterministic to parse and follows the
  "when in doubt, report" rule.
- The cap on the "already reported" list in the prompt, and how keys are normalized.
- Retention of old runs (suggested: 90 days, like places visited) and of `only_new` items
  (long enough that an opening seen once does not come back).
- Icons, spacing and wording of the panel, the sheet and the switch, within the app's
  current design (panels, Archivo, the existing palette).
- Pagination size and the shape of the day grouping.

## Related

- **Cut texts, app-wide (done first, separate change, commit `66f56fa`):** texts with no
  page to open are shown whole or open in full on a tap (`widgets/expandable_text.dart`);
  rows that open their full page keep a short preview. New routine texts follow the same
  rule (use `ExpandableText` where a preview has no page behind it).
- Places visited on Today (point 15 of `next-step`): to design next, likely in "Your day".
