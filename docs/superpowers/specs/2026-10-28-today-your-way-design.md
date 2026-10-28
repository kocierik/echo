# Today, your way — design

Date: 2026-10-28. Status: agreed in conversation and checked by a builder; to be approved.

## Why

Point 15 of `next-step`: where the user has been (Profile → Places visited) is too hidden.
Talking it through, the real problem is wider: Today is not clear even to its user. It
shows many things in a fixed order, some rarely looked at, and misses the day's agenda.
The user wants Today to show **what they use most**, and to be able to **hide and reorder**
its sections, since other people will care about other things (places, for one).

What the user looks at, in their words and order (28/10): routines, to do today, the
appointments, the conversations, the people they talked with, Saved, and where they have
been.

## Goals

- Today's sections, by default in this order:
  1. **From your routines** (exists, `RoutinesTodayPanel`).
  2. **To do today** (exists, `TodoPanel`).
  3. **Coming up today** (new): today's appointments **still to come**, from the iPhone's
     calendar; past ones are not shown (user, 28/10).
  4. **Your day**: today's conversations (exists, `YourDayPanel`).
  5. **People**: who the user talked with (exists, memory's people section).
  6. **Saved** (exists).
  7. **Where you've been** (new on Today): today's stays.
  8. **Earlier days** (exists, `EarlierPanel`): the past days, their digests and "This
     week". Visible by default, last (user, 28/10): it is the only way to the past.
- **Edit Today**: a page reached from the bottom of Today where each section can be
  **hidden** (a switch) and **moved** (drag), plus "Reset to default" (user: both, 28/10).
- **"Echo is working on…" moves to Ask**: shown at the bottom of the thread with Echo,
  where its answer then arrives, as a bubble of Echo at work; it leaves Today (user, 28/10).
- Where you've been shows only when Places visited is on in Profile (off by default), so
  people who do not want it never see it (user agreed, 28/10).

## Non-goals

- Spoken answers from the phone (TTS): the next project, after this one (user, 28/10).
- Today's layout saved on the server or shared between phones.
- New data: everything shown exists already (calendar on the phone, visits, runs, tasks,
  conversations, people, Saved).
- A map drawn inside Today.

## Anti-goals

- Something that needs the user (an action to confirm) hidden by their own layout.
- A section the user hid coming back by itself after an update.
- Today slower to open than now, or empty while it loads things it used to show at once.
- Cut texts with no way to read them in full (the app-wide rule since `66f56fa`).

## Decisions

### Fixed, not customizable (agreed with the user, 28/10, proposed by the designer)

- **Needs you** (actions to confirm) stays first and cannot be hidden or moved: the only
  thing on Today that expires.
- The **plan line** ("near or past this month's speech") shows by itself, only near or past
  the limit, as today.
- The wearable's warnings (disconnected, Bluetooth off, …) and the one-off tips (new
  firmware) keep their place at the top, as today: they are about the device, not sections.

### Search: an icon, not a section

*(Designer's call, after the builder check, 28/10.)* The search over the whole memory
(today a field at the top of Today, the only one in the app) becomes a **search icon fixed
in Today's header**, opening its own search screen with the results (today's
`MemorySearchView`). It is not a section of Edit Today, so it can never be lost.

### Earlier days stays visible

The first proposal hid Earlier days by default, assuming the past stayed reachable from
Your day; it does not (`DayScreen` shows one day, and Earlier days is the only way to past
days, their digests and the week). Agreed with the user (28/10): Earlier days is visible by
default, the last section, and can be hidden like any other.

### Coming up today

- Replaces the top card's "coming up" moment (today: one event within the hour).
- Reads the iPhone's calendar from now to the end of today (the existing
  `PhoneActionsService` / calendar access); none without calendar permission, and then
  the section is not shown.
- *(Agreed:)* the recap "what was said last time" (`POST /api/notifications/coming-up`)
  stays, under the event that starts within the hour.
- All-day events of today are listed first, as "All day".

### Where you've been

- Today's stays (`GET /api/places/visits`, filtered to today), the time and the place's
  name or address. Tapping a stay opens it in the phone's maps (Apple Maps on iOS, Google
  Maps on Android, as `utils/directions.dart` does for Saved). "See all" opens Places
  visited.

### Edit Today

- Order and visibility are kept **on this phone** (app preferences), not on the server
  (agreed, 28/10).
- A section added in a later version appears in its default place, visible, unless the
  user's saved layout says otherwise; a hidden section stays hidden.
- A visible section with nothing to show today is left out, as today (no empty panels).

### Echo is working (in Ask)

- While a voice request or a photo is in progress, the thread with Echo shows a bubble at
  the bottom with what it is working on ("Working on: che tempo fa domani"); it goes away
  when the answer arrives. Uses the same server source as today (`GET
  /api/actions/voice-working`).
- Today no longer shows it.

### The top card's other moments

*(Designer's call, told to the user, 28/10.)* The top card today also shows "Now" (the
conversation going on) and "So far today". With Your day on Today they repeat it, so the
top card keeps only Needs you, and what "Now" shows moves into Your day's live row (today
only "Now · Recording"): how long it has been going, who is there, its title and the last
line heard (`_loadLastLine` stays). "So far today"'s line of main titles is dropped (Your
day lists the conversations and has the totals). With Your day hidden, the conversation
going on is not on Today: the user's choice.

## Constraints

- Flutter app only (`mobile/`); no server change is expected.
- App strings in English.
- `flutter analyze` and `flutter test` pass; Today's existing tests are updated, not dropped.
- One user today, but the layout must make sense for others (the reason for Edit Today).

## Left to the builder

- How Edit Today looks within the app's style (panels, switches, drag handles), and how
  it is reached (a row at the bottom of Today; a header action is fine too).
- How many stays and events are shown before "See all".
- How Ask polls "working" while it is on screen (interval, stop when the app is in the
  background) and the bubble's look.
- The keys of the saved layout and its migration when sections are added.
