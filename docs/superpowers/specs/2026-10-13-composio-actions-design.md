# Echo Actions via Composio — Design

Date: 2026-10-13. Status: draft for approval.

## Intent

The user wants to ask Echo to do things in their other tools and get the result
back, for example:

- "Echo, riassumimi le ultime mail" → a summary of the latest Gmail messages;
- "riassumi i messaggi del canale #team" → a summary of Slack messages;
- "Echo, segnami il dentista giovedì alle 15" → an event in Google Calendar.

Today Echo has hand-written clients (Todoist, Notion, Telegram, Slack, Google
Calendar) that fire automatically on extracted entities. None has been verified
against the real APIs, Telegram/Slack never fire, and Google requires a
self-managed OAuth app (7-day token expiry in "Testing", security review for
Gmail read access). The user chose **Composio** to manage accounts and tool
calls, accepting that account tokens are held by Composio and that read content
(emails, messages) passes through Composio and OpenAI.

This replaces the "Composio Phase" of the core beta spec
(`2026-10-01-core-beta-design.md`) and is built now, in parallel with the beta
hardware tests.

## Decisions taken with the user

1. **Two entry points, same capabilities.**
   - Chat (Ask), typed or dictated.
   - Voice: speaking to the wearable and **addressing Echo by name**
     ("Echo, …"). Speech not addressed to Echo never triggers an action.
2. **Only on explicit request.** No more automatic actions from overheard
   speech: the automatic integrations and the Rules engine go away.
3. **Where answers go.** Voice requests and their answers appear in a chat
   conversation in Ask, plus a phone notification with a preview.
4. **Confirmation policy.**
   - Run immediately: reading/summarizing, and creating things for the user
     (event, task, note, draft).
   - Ask for in-app confirmation first: anything sent to other people or
     destructive — send an email or a message, modify or delete.
   - Every executed action is recorded in an audit log.
5. **Apps: what Composio actually supports.** Initial set: Gmail, Google
   Calendar, Slack, Telegram (bot), Todoist, Notion; other Composio toolkits can
   be searched and connected from Integrations. Personal WhatsApp and Instagram
   DMs are out (no official API). Telegram works only as a bot (messages sent to
   the bot and groups it is in).
6. **Language.** App texts in English; answers in the language of the request
   (already implemented for chat).

## Goals

- Read and summarize: latest emails (filters such as unread, from someone,
  today), Slack channel/thread messages, calendar agenda, Telegram bot messages.
- Create: calendar events (default duration 1 hour, user timezone), tasks,
  notes, email drafts.
- Change/send with confirmation: send an email or message, move/rename/delete
  an event, complete/delete a task.
- Connect and disconnect accounts from the app without touching `.env` beyond
  one Composio API key.
- Mixed requests are possible: "what did Marco say about the offer, and is it
  in my email?" (memory + tools in one answer).

## Non-goals

- Automatic actions from things said in conversations (removed).
- Reading personal WhatsApp/Instagram/Telegram user chats (no official API;
  unofficial libraries risk a ban).
- Spoken answers (TTS on the phone) — possible later.
- Apple push notifications (APNs) for instant delivery — needs a paid Apple
  Developer account; possible later.
- Storing read emails/messages in Echo's memory (they are read on demand).
- Multi-user support beyond the existing single API key user.
- Self-hosting Composio.

## Anti-goals (failure even if it "works")

- Echo acts on speech that was not addressed to it.
- Something is sent to another person, modified or deleted without the user
  tapping Confirm.
- Audio or full transcripts are sent to Composio.
- A failed action is reported as done, or fails silently.

## Behaviour

### Chat

- `POST /api/query` keeps the current fast path for memory questions (RAG).
- When the message needs a tool (my call: reuse the existing cheap pre-check —
  keywords, follow-up to an action reply — plus the LLM intent check, extended
  from calendar to all connected toolkits), the backend runs an **agent loop**:
  the query LLM (`LLM_QUERY_MODEL`, OpenAI tool calling) with:
  - the Composio tools of the user's **connected** toolkits only;
  - a `search_memory` tool wrapping the existing RAG retrieval (my call: lets
    mixed questions work).
- Read/create tools execute inside the loop. Confirm-tier tools are **not**
  executed: the loop stops and returns a pending action (see Confirmation).
- The final answer is in the language of the request and is stored in the chat
  session like any other answer; raw tool results are not persisted.
- The current calendar behaviours must survive through the system prompt and
  tools: default duration 1 h, `USER_TIMEZONE`, a new time keeps the day and
  duration, find the event by title/day when no id is known.

### Voice

- After STT, the backend checks each new transcription for an address to Echo:
  the name at or near the start of an utterance, tolerant to STT spellings
  ("Echo", "Eco", "Hey Echo", "Ehi Echo"), then an LLM check that it is a
  request to the assistant and not a mention ("ho comprato un Echo").
- A request can span several Segments (the wearable cuts every ≤ 6 s): the
  command is the text from the name onward plus the following Segments of the
  same Conversation until a pause (builder decides the exact pause; about 3 s
  of silence or 15 s maximum is a reasonable start).
- The request runs through the same agent as chat. Its question and answer are
  appended to a dedicated chat session titled **"Voice requests"** (one per
  user, created on first use, shown pinned at the top of Ask history).
- The transcript text keeps the request (it is still memory); the entity
  extraction ignores the command part so "segnami il dentista" does not also
  become an extracted task (my call).
- The phone shows a local notification with the first lines of the answer;
  tapping it opens the Voice requests session. **Delivery is "at the next
  occasion"** (decided with the user): the app checks for new voice answers
  whenever it runs — on every BLE wake/segment upload and when it comes to the
  foreground — and schedules the local notification then. The answer is always
  in the chat immediately; only the notification may be late while the user is
  silent and the app is suspended.

### Confirmation

- Each Composio tool is classified as `read`, `create` or `confirm`:
  - by an explicit table for the initial toolkits (e.g. `GMAIL_SEND_EMAIL` →
    confirm, `GMAIL_CREATE_EMAIL_DRAFT` → create, `*_DELETE_*` → confirm);
  - any tool not in the table defaults to `confirm`.
- A confirm-tier call creates a **pending action** (tool, arguments, a
  human-readable summary such as "Send email to marco@… — Subject: …", source
  chat/voice, session, expiry). The answer message carries an action card.
- The app renders the card with **Confirm / Cancel** (the core beta reserved
  this UI). Confirm executes exactly the stored arguments; Cancel discards.
  Pending actions expire (my call: 30 minutes) and can be confirmed only once.
- The result ("Sent." / the error) is appended to the same session.

### Audit

- Every executed tool call (any tier) is logged: time, source (chat/voice),
  toolkit, tool, a short argument summary, outcome, error. Full email bodies or
  tool results are not stored.
- Viewable in Settings → Automations → Activity (my call: simple list, newest
  first).

### Accounts (Integrations screen)

- Lists the initial toolkits with connected/disconnected state, plus search over
  other Composio toolkits.
- Connect: backend asks Composio for a connection link for this user, the app
  opens it in the browser, the user logs in with the provider, Composio stores
  the account; the screen refreshes the state on return.
- Disconnect removes the Composio connected account.
- Composio's user id is the Echo `user_id`. Composio-managed auth configs are
  used (no Google Cloud OAuth app of our own).

## Privacy

- Sent to Composio: tool name and arguments only (e.g. an email search query, an
  event title and time). Never audio, never full transcripts.
- Sent to OpenAI: the request, the tool results needed for the answer (e.g.
  email snippets/bodies to summarize), as with RAG today.
- Stored by Echo: the chat question and final answer, pending actions, the audit
  log. Not stored: raw tool results.

## What goes away

- `app/integrations/` (engine, clients, providers.json), `rules_engine.py`,
  `/api/rules`, `/api/integrations` (old shape), the Google OAuth router and
  `oauth_state`, `calendar_service.py` and the calendar part of
  `chat_actions.py` (replaced by Composio Google Calendar), the automatic
  `trigger_integrations`/`evaluate_rules` calls in the analysis pipeline and the
  `allow_side_effects` plumbing.
- Mobile: the Rules screen and the old Integrations config dialogs.
- DB: a migration drops `rules` and `integrations` (my call: their data is not
  migrated; the user reconnects accounts through Composio).
- Settings `GOOGLE_*`, `OAUTH_STATE_SECRET`, `DEFAULT_EVENT_DURATION_MINUTES`
  (the 1 h default moves to the agent prompt) are removed; `COMPOSIO_API_KEY`
  is added.

## Constraints

- Backend Python/FastAPI, worker for voice requests (the request must not block
  STT/analysis of other Segments); mobile Flutter, English UI.
- Composio free plan (tens of thousands of tool calls per month; single user).
- The corporate proxy blocks some Composio/vendor docs: the builder must check
  the current Composio Python SDK and auth-link API before coding (pricing and
  APIs changed several times in 2026).
- Behind an adapter (`ActionProvider`: list connectable toolkits, connections,
  connect link, disconnect, tools for a user, execute) so Composio can be
  replaced; all tests use a fake provider, no network.
- Failures are explicit to the user (provider unreachable, account
  disconnected, tool error) and covered by tests.

## Left to the builder

- Exact Composio SDK calls and versions; tool schemas; prompt wording.
- Wake-name detection details within the rules above; pause thresholds.
- Table/column names; API routes for actions and connections; card layout
  consistent with the existing chat UI.
- Ordering of the work (suggested: adapter + chat agent + confirmations first,
  then voice, then removal of the old code).

## Open questions

None. (Notification timing was decided: next occasion, no APNs.)
