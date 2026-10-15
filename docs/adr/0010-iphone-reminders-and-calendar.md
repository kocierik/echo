# Reminders and Calendar of the iPhone, run by the app

Echo could only act on apps reached through Composio (Google Calendar, Todoist…). Many users
keep their reminders and calendar in the iPhone's own apps, and a reminder there is what
actually alerts them at the right time. Those apps live on the phone (EventKit): the server
cannot reach them, the app can.

## Decision

- **Tools like any other app's**: `applereminders` (create, list open reminders) and
  `applecalendar` (create, list events) are offered to the action agent next to Composio's,
  by a provider (`actions/phone_provider.py`) that the router and the agent see as one with
  Composio. Creating runs at once (CREATE tier), as for Google Calendar: nothing involves
  other people (no invitations are sent).
- **Run on the phone**: a call becomes a `phone_action` command on the queue the app already
  long-polls for photos (`GET /device/commands`); the app runs it with EventKit
  (`ios/Runner/EventKit`) and posts the result (`POST /device/commands/{id}/result`), which the
  server waits for up to 25 s. A command not picked up within 15 s did nothing ("could not
  reach the iPhone"); one picked up but not answered may have run, so the user is told to
  check, as for a Composio timeout.
- **Turned on in the app**: Settings → Automations → On this iPhone, one switch each; iOS asks
  for full access the first time. The app tells the server which are on and allowed
  (`PUT /device/phone-apps`) when they change and every few hours. Without them nothing
  changes: the provider is the same Composio one and the intent check never names them.
- **Briefings**: with the calendar on, the app sends its next 36 hours of events with the
  notifications refresh (`POST /notifications/upcoming`), so a meeting in the iPhone's
  calendar gets its briefing too; one also in Google Calendar is briefed once.

## Considered Options

- **A Flutter plugin** (`device_calendar`): events only, no Reminders, and one more native
  dependency to keep up with; the bridge is about 250 lines of Swift.
- **Push to the phone (APNs)**: would reach a suspended app, but needs a paid Apple developer
  account. The long poll works while the app runs, which it does while the wearable is
  connected.
- **Syncing Echo's tasks into Reminders**: two lists of the same things to keep in step;
  Echo's tasks stay Echo's, and Reminders get what the user asks for.

## Consequences

- With the app suspended (wearable away, app closed) the iPhone's apps are unreachable and
  Echo says so.
- Event and reminder titles, times and guests reach the user's own server when asked for, and
  the next 36 hours of the calendar with each notifications refresh.
