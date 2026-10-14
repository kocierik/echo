# Echo Memory Experience — Design

Date: 2026-10-14. Status: decided by Claude on the user's delegation ("scegli tu come procedere"),
phase 1 in progress.

## Intent

The backend already knows a lot — conversations with titles and summaries, people, tasks with due
dates, events, ideas, notes, daily digests — but the app shows almost none of it. Transcripts lists raw
5–6 s audio Segments, Today shows one Segment, eight tasks and *yesterday's* digest, and search only
filters the 50 Segments already loaded. The memory can only be reached by asking the chat.

This design makes the memory browsable, makes Today a real picture of the day, and takes the best
patterns of the competitors while fixing what their users complain about.

User decisions: the app UI stays in **English**; the chat must understand and answer in any language
(it already answers in the language of the question). The web UI in `backend/static/` is not used and
is removed.

## What the competitors do (October 2026)

Sources: Omi's open-source Flutter app (`BasedHardware/omi`, `app/lib/pages`), docs.omi.me, reviews of
Bee, Limitless and Plaud (layer3labs.io, craftnote.com, legendmemory.ai), and the July analysis
([2026-07-25-competitive-analysis.md](2026-07-25-competitive-analysis.md)).

| Pattern | Omi | Bee | Limitless | Plaud | Echo today |
|---|---|---|---|---|---|
| Conversation list with title, summary, emoji | ✅ home | ✅ diary | ✅ | ✅ | ❌ Segments |
| Conversation detail: Summary / Transcript tabs | ✅ | ⚠️ | ✅ | ✅ | ❌ |
| Action items inside the conversation | ✅ | ✅ | ⚠️ | ✅ | ❌ |
| Tasks tab grouped by due date (Today/Tomorrow/Later) | ✅ | ✅ | ❌ | ❌ | ⚠️ 8 tasks on Today |
| Daily summary / recap | ✅ | ✅ (strongest) | ✅ | ❌ | ⚠️ yesterday's, mislabelled |
| Global search | ✅ | ✅ | ✅ | ✅ | ❌ local filter |
| Named speakers / people | ✅ name a speaker | ❌ | ✅ | ✅ diarization | ⚠️ self/other only |
| Facts about the user ("memories") | ✅ | ✅ facts | ❌ | ❌ | ⚠️ entities, not shown |
| Events → add to calendar | ✅ | ⚠️ | ❌ | ❌ | ❌ |
| Acting on other apps | ⚠️ marketplace apps | ⚠️ | ❌ | ❌ | ✅ Composio, with confirmation |
| Voice commands to the assistant | ⚠️ | ❌ | ❌ | ❌ | ✅ "Echo, …" |
| Consent cue for bystanders | ❌ | ❌ | ✅ chime | ❌ | ❌ |
| Self-hosted, no subscription | ⚠️ self-host possible | ❌ Amazon | ❌ discontinued | ❌ | ✅ |

What reviewers complain about, and what Echo does instead:

1. **Wrong action items** ("casual chat labelled as a to-do" — Bee). Echo shows, for every task, the
   sentence it came from (`source_transcription_id`) and a one-tap **Not a task** that deletes it.
2. **Capturing more than anyone reviews** (Bee). Echo leads with a short recap and a small
   **Needs you** list (new tasks, pending confirmations), not with an endless feed.
3. **Rough app UI** (Bee, Omi "rougher edges"). Echo keeps one consistent design system, every state
   designed (loading, empty, error, offline, unpaired), 44 pt targets and screen-reader labels.
4. **Cloud lock-in and subscriptions** (all). Echo stays self-hosted; privacy is visible: the mute
   needs the device's acknowledgement and Composio sees only tool arguments.
5. **Acting is an app store** (Omi). Echo acts on the user's own accounts through one agent, from chat
   or by voice, with confirmation for anything that sends, edits or deletes.

## Information architecture

Four tabs (Omi and Bee both separate the diary from the tasks; Ask stays one tap away):

| Tab | Content |
|---|---|
| **Today** | Compact device row, recap of the day so far, Needs you, today's conversations, tasks due today |
| **Memories** | Conversations grouped by day (search across everything), and People |
| **Tasks** | Open tasks grouped Overdue / Today / Tomorrow / This week / Later / No date; Done |
| **Ask** | Chat (any language), history, Voice requests |

Settings stays behind the gear in the status strip.

## Screens

### Memories → Conversations
- Day groups (Today, Yesterday, weekday + date). Each card: emoji, title (fallback: first words of the
  transcript), two-line summary, time range and duration, up to three people, task count.
- An open conversation (still capturing) shows **Live** with a pulsing dot; one being analysed shows
  **Processing**.
- Search field at the top: server-side search over titles, summaries, transcripts and entities.
- Pull to refresh; pagination by day.

### Conversation detail
- Header: emoji, title, date, time range, duration, people chips.
- **Summary** tab: the summary, then sections only when non-empty: Tasks (checkable, each with its
  source quote), Events (with **Add to calendar** when Google Calendar is connected — phase 3),
  People, Ideas & notes.
- **Transcript** tab: the Segments in order, each with time and speaker (You / Other / Unknown);
  tapping one opens the existing correction sheet.
- Actions: **Ask about this** (opens Ask with the conversation as context), Delete conversation.

### Tasks
- Groups by `due_date` in the user's day; overdue in red. Row: checkbox, name, due date, source quote
  on expand, link to the conversation.
- Swipe or long press: **Not a task** (delete), edit name/due date.
- Done section, collapsible; completing shows an Undo snackbar.

### Today
- One compact device row replaces the 148 pt hero and the duplicated states (status strip, hero and
  privacy button all said the same thing); mute stays one tap.
- Recap card: today's conversation count, minutes captured, people met, tasks created; yesterday's
  digest labelled **Yesterday** and collapsed.
- Needs you: pending action confirmations, tasks created today (accept by leaving, **Not a task** to
  drop).
- Today's conversations (compact cards, newest first) and tasks due today.
- Unpaired: a **Pair Echo** card instead of "Reconnect".

### People (phase 2)
- List of person entities by last mention; a person page with what was said, tasks and conversations
  involving them, and "Ask about <name>".

### Ask (phase 3)
- Streaming answers; sources open the conversation; suggestions from today's conversations; a
  "Connect an app" hint when a request needs one.

## Backend changes

- `GET /api/conversations`: add `emoji`, `duration_s`, `people` (up to three names), `task_count`,
  `is_open`; filters `date_from`, `date_to`; keep `limit`/`offset`.
- `GET /api/conversations/{id}`: transcript items get `segment_id`, `speaker_label`; entities get
  `source_text` (the sentence they came from).
- Conversation summaries also produce an `emoji` (migration 009 adds the column).
- `GET /api/search?q=`: conversations (title, summary, transcript text) and entities (name, content),
  case-insensitive, newest first.
- `GET /api/entities/tasks`: add `source_text` and `conversation_id`.
- The web UI (`backend/static/`) and its static mount are removed; `/admin` endpoints stay.

## Phases

1. **Memories + Tasks**: backend fields and search, Memories tab (list, search, detail), Tasks tab,
   web UI removal.
2. **Today + People**: compact device row, recap, Needs you, today's conversations, unpaired card;
   People list and person page.
3. **Ask**: streaming, source links, contextual suggestions; Add to calendar from events.

Out of scope here: named speaker identification (needs diarization), consent chime (firmware),
proactive notifications.

## Testing

Backend: pytest for the new fields, search and summary emoji. App: widget tests for every screen
state (loading, empty, error, content, Live/Processing), task grouping by date, Not a task and Undo.
Layouts are checked at 320 pt with 1.3 text scale, light and dark, as the existing tests do.
