# App tabs redesign: Today, Ask, Profile — Design

Date: 2026-10-22. Status: approved by the user in chat (22/10), mockups agreed.
Mockups: https://claude.ai/artifact/PhA25EoVg25qKwRS2YNn9H (private to the user): "Today v2",
"Ask A: one thread with Echo", "Ask: a photo answer", "Profile". "Ask B" and the first "Today"
were the alternatives not chosen.

## Intent

The app has three tabs today: Today, Ask (centre, hold to dictate) and Memories. Settings are
hidden behind a tap on the device pill, so the user does not find them. What Echo does on its own
(answers to voice requests, photos taken by calling Echo, soon routines) lands in a "Voice
requests" chat that sits in Ask's history, out of sight: the user does not know where to look
after "Ehi Echo, spiegami cosa c'è scritto qui". And a photo request phrased as "explain this"
is not reliably understood as one.

The user wants:

- **Profile** instead of Memories: one visible place for every setting.
- What was in **Memories** moved into **Today**, and Today richer than it is now ("un po'
  spoglia").
- **Everything Echo answers in Ask**: voice answers, photos with their answer, routine answers.
- "What is in front of me" requests **understood as said** ("spiegami", "traduci", "cosa c'è
  scritto"), answered from the photo.

## Goals

1. **Tabs: Today · Ask · Profile.** Ask stays in the centre with hold-to-dictate. Memories is
   removed as a tab; nothing it offered is lost.
2. **Ask is one thread with Echo** (mockup "Ask A"). Typed questions, voice requests (labelled
   "By voice" with the time), photos with the question and answer, and routine answers, in time
   order, in the same conversation. Past chats stay reachable (the history button); "New chat"
   still starts a separate typed chat, which does not receive voice, photo or routine messages.
   Opening Ask shows the thread at its latest message.
3. **Photo answers in Ask** (mockup "Ask: a photo answer"): the user's words, the photo large (tap
   for full screen, as today), the answer. Under it, quick follow-ups that send a question about
   the same photo: "Translate it", "Ask more" (focuses the composer), and "Remind me…" only when
   the answer names a date or time.
4. **Photo requests understood.** A voice or chat request about what the user is looking at
   routes to the camera even when phrased as a task on it ("spiegami questo", "cosa c'è scritto
   qui", "traducimi il cartello", "quanto costa questo", "explain this", "what does this say"),
   and the vision model answers that request with the user's whole sentence (it already gets
   `photo.question`; the routing is the gap to verify).
5. **Today, richer** (mockup "Today v2"), top to bottom:
   - Header: the day ("TUESDAY 21 OCTOBER"), a greeting with the user's name, the device pill.
   - **One top card that changes with the moment** (the first that applies): something to confirm
     (a pending action, with Confirm/Cancel) → an event within the next hour, with what was said
     last time with its people or about its title ("Review with Ada: the budget, the November
     date") → the conversation going on now (duration, who, the last line heard) → "So far
     today" (the day's summary in two lines and three counts: conversations, time talked,
     people).
   - **To do today**: tasks with a checkbox, and the user's promises among them ("Luca: the
     slides by Friday"); no separate promises section.
   - **Your day**: conversations and photos in time order, each with a one-line summary; a photo
     row shows its thumbnail and title.
   - **People today** (who came up today, then "All" to the people list).
   - **Earlier**: past days, each with its count and main topic; a tap opens the day.
   - **Search** over the whole memory (what Memories' search did), at the top under the header.
   - Device problems, tips and the firmware notice keep their places above the top card.
6. **Profile** (mockup "Profile"): the account (name, email, spoken language), the Echo device
   card (state, battery, firmware; tap → the device screen), then the settings grouped:
   - "Echo does": Apps, Routines (when built), Notifications, Activity;
   - "You": Voices, Language, Privacy, Appearance;
   - then "What Echo can do", and one row for Devices, Server connection, Diagnostics and About.
   The device pill on Today and Ask stays, and opens the device screen.

## Non-goals

- New memory features (a graph, a profile of what Echo knows about the user): separate roadmap
  items.
- Routines themselves: designed in `2026-10-21-web-search-and-routines-design.md`; this design
  only says where their answers appear (the Ask thread) and where they are managed (Profile →
  Routines).
- Push notifications when the app is closed (APNs, paid account).
- Restyling the theme: same palette, type (Archivo) and components.

## Anti-goals

- A setting or a Memories feature that can no longer be reached.
- A Today that is a wall of boxes: one top card, then lists; empty sections are hidden, not
  shown empty.
- Voice or photo answers that the user has to hunt for: they are always at the bottom of Ask's
  thread, and the notification opens the thread at that message.
- A photo answer that ignores what was asked ("spiegami" answered with a description).

## Constraints

- Flutter, iOS and Android; English UI copy only; the AI answers in the user's language.
- The existing widgets and services (`EchoAppShell`, `EchoNavBar`, `HomeScreen`, `MemoriesScreen`
  parts, `ChatScreen`, `SettingsScreen` sub-screens, `VoiceUpdatesService`) are reused, not
  rewritten from scratch.
- The selected-tab preference (`echo_selected_tab_v3`, index 2 = Memories) must not open a wrong
  tab after the update: bump the key or map the old index to Today.
- Tests one suite at a time (app ~1 min, backend ~30 s); TDD; the work lands on main, verified.

## What the user decided (22/10)

- Ask version A (one thread), not B (a pinned "From Echo" section).
- Today with the adaptive top card, promises inside the to-dos, the rest as listed.
- Profile as drawn.

## Calls made by Claude (check these)

- The "one thread" is the existing per-user voice session (`ChatSession.kind == "voice"`)
  promoted to the main thread: typed questions in Ask go there unless the user starts a new chat;
  its title becomes "Echo". Routine answers go there too (this replaces the separate "Routines"
  chat of the routines design).
- Quick follow-ups under a photo: Translate, Ask more, Remind me (only with a date or time).
- The device pill stays on Today and Ask.
- Coming-up recaps use the phone calendar the app already reads and the memory (people and title
  of the event); with no phone calendar the card skips that case.

## Answers to the builder check (Claude's calls, 22/10)

1. **The camera from a typed question: no.** Only voice requests route to the wearable camera
   (as today, `camera=True`); in Ask the camera button takes the photo, and the typed question in
   the composer goes with it as the photo's question. Goal 4 is the voice path: routing prompt and
   evals.
2. **"So far today" without a new model job.** Built from what exists: today's conversation
   titles and summaries (the two lines name the main ones, e.g. "Stand-up with Marco, lunch with
   Ada, the Atlas call") and the three counts. No intra-day LLM digest (cost); the 04:00 digest
   stays the summary of a past day.
3. **The user's name:** a nullable `users.name`, returned by `/api/auth/me` and set from Profile
   (a "Name" row; prefilled from the own voice profile's name when there is one). No onboarding
   step. Without a name the greeting has none ("Good afternoon").
4. **Today and Memories parts not listed above:**
   - `WorkingSection` ("Echo is working on it") stays on Today, above the top card, like device
     problems.
   - `ActsInPanel` ("Echo can act in") leaves Today: Profile → Apps is its home.
   - The weekly summary becomes the first row of "Earlier" ("This week"), opening it.
   - The daily digest is shown at the top of a past day's screen.
5. **Several actions to confirm:** the top card shows the one that expires first, with "+N more"
   opening the full list (today's `NeedsYouSection` as a pushed screen). Pending actions keep
   their notification, so none times out unseen.
6. **"Remind me…":** shown when the photo analysis returns a time. The vision JSON gains `"when":
   "<ISO local datetime>" | null` (set when the photo shows a date or time worth a reminder: a
   notice, a ticket, an appointment card). The chip sends a follow-up in the user's language
   (account language: "Ricordamelo <when>" / "Remind me <when>") through Ask, so the agent
   creates the reminder with the usual rules (phone Reminders when on, else an Echo task).
7. **The device screen:** a new "Echo" screen built around `DeviceInstrumentPanel` (state,
   battery, mute, reconnect, pairing, firmware update) plus what `DeviceDetailScreen` shows (and
   its "Forget device"). The pill on Today and Ask and the Profile device card open it; the
   firmware tip's action becomes "Open Echo".

## Left to the builder

- How typed questions and voice requests share the thread's history (Redis context and the
  stored messages) without double entries or lost context.
- The exact data for "So far today" counts and "the last line heard" (existing endpoints or a
  small new one).
- The routing fix for photo requests: prompt wording in `actions/availability.py`, with cases in
  `evals/cases/routing.json` for the phrases above (Italian and English) and negatives ("spiegami
  cosa ha detto Marco" stays memory).
- Where the people list and a past day open (pushed screens from Today).
- Migration of the old tab index.
