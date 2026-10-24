# Who is in front of you — Design

Date: 2026-10-24. Status: approved by the user in chat (24/10, "approvo chi hai davanti").
Roadmap: Fase 8, "Echo riconosce chi hai davanti".

## Intent

Echo already briefs the user 10 minutes before a calendar event with a person ("In 10 min: Review —
Ada: …"). Many encounters are not in the calendar: Marco met in the street, a call, a colleague who
drops by. Echo hears them and already knows the voices it was taught (Profile → Voices, voice
fingerprints, ADR 0008). When a known person starts speaking and there is something worth knowing,
the phone should say it at once: "Marco: you promised him the quote by Friday · last time: the Atlas
launch".

## Goals

1. **Triggered by a voice**: a newly transcribed segment whose voice matches a known person (the match
   threshold already used to label lines, not the "Marco?" suggestion) starts a check for that person.
2. **Only with something to say**: the same facts as the meeting briefing (`_what_to_know`: open
   promises to them, what they promised the user, the last conversation with them and its gist, an
   event with them soon). Nothing to say, no notification.
3. **Rare**: at most once per person every 4 hours; never for the user's own voice; never for a person
   already briefed for a calendar event within the last hour; the same rules as the other notices (the
   briefings switch, quiet hours 22–8, at most three a day in total).
4. **At once on the phone**: the server sends a device command (`person_brief`, with title, body and
   the person) on the queue the app long-polls; the app shows it as a local notification, tapping opens
   the person's page. While the app is not running it is dropped (a late "who is in front of you" is
   noise).
5. **Seen in the app**: the notification settings name it ("When someone you know starts talking"),
   under the briefings switch; What Echo can do gains the example.

## Non-goals

- Recognising unknown voices or faces; asking "who is this?" in real time.
- An LLM call per encounter: the text is built from the stored facts (cheap, fast).
- Push when the app is closed (APNs).

## Anti-goals

- A notification every time someone talks; a notification about the user themself; a briefing during
  a long conversation every few minutes.
- Saying something wrong because the voice match was weak: only the confident match threshold.

## Constraints

- Backend: the STT worker / voice labelling (`services/voice_profiles.py`), notification rules and
  `_what_to_know` (`services/notifications.py`), device commands (`services/device_commands.py`); app:
  `DeviceCommandLoop`, `NotificationService`, notification settings. English copy. Tests one suite at a
  time; TDD; main, verified.

## Calls made by Claude (check these)

- 4 hours per person; skip within 1 hour of a calendar briefing for them; counted in the three a day.
- Built from stored facts, no model call.
- Dropped when the phone does not take the command within 2 minutes.

## Left to the builder

- Where in the transcription flow the check runs, and how the per-person cooldown is kept (Redis key).
- The exact notification copy.
