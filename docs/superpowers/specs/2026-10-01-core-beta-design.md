# Echo Core Beta Design

## Goal

Ship a personal, iOS-first Echo beta that can listen continuously through the
wearable, relay audio while the iPhone is foregrounded, backgrounded, or locked,
and make the resulting memory understandable and controllable from the app.

The beta is for one user, one iPhone, one wearable, one self-hosted backend, and
one API key. Android remains buildable but is not a release gate.

## Success Criteria

The core beta is ready when one installed iOS release build passes a continuous
two-hour test with:

- foreground, background, and locked-screen BLE relay;
- at least 20 accepted Segments with no logical duplicates or silent loss;
- automatic reconnect after Bluetooth off/on and out-of-range recovery;
- backend outage recovery without premature wearable dequeue;
- persistent app-controlled mute across disconnect and wearable reboot;
- observable PSRAM overflow with oldest-first loss and a dropped count;
- transcript and speaker correction followed by safe reanalysis;
- complete resumable chat history;
- conversation deletion and audio-retention behavior verified;
- no crashes and no unbounded loading state.

The two-hour test covers foreground, background, locked-screen, and iOS-managed
termination/restoration behavior. It excludes a user force-quitting the app.

The separate battery gate is 12 hours of measured use with a 1200–1500 mAh
protected 3.7 V LiPo connected to the XIAO charger. Battery validation is deferred
until the hardware arrives. No sleep optimization is included before current draw
is measured in silence, speech capture, and BLE transfer.

## Product Principles

- The wearable listens continuously but stores audio only when VAD detects speech.
- Privacy state must be explicit and reachable in one tap.
- The newest memory wins when volatile storage is exhausted.
- Technical diagnostics stay out of the daily workflow.
- Strong color always communicates state or required action.
- Audio and full transcripts remain in Echo; third-party integration providers
  receive only the minimum action arguments.

## Scope

### Included

- iOS background BLE central mode and state restoration.
- Saved wearable identity and automatic reconnect.
- BLE Secure Connections bonding with one iPhone.
- Global connection and wearable status.
- Persistent app-controlled mute.
- PSRAM drop-oldest overflow and dropped-Segment reporting.
- Essential local notifications.
- Cellular upload by default and optional Wi-Fi-only policy.
- Complete chat history.
- Transcript and speaker correction with side-effect-free reanalysis.
- Completed/failed audio retention and complete conversation deletion.
- Unified API errors and request timeouts.
- Logout that clears local credentials and pairing metadata.
- English adaptive light/dark Flutter UI matching
  `docs/mockups/echo-mobile/`.

### Deferred

- Thirty-minute persistent offline storage (microSD).
- Physical mute control.
- Battery percentage before battery sensing hardware exists.
- Android background service parity.
- TestFlight and App Store release.
- Multiuser accounts and OAuth login.
- Sleep/power optimization before measurement.
- Composio implementation and external action execution.
- Public App Store distribution.

## Architecture

The core beta is delivered in three dependency-ordered workstreams:

1. **Device reliability:** firmware protocol, iOS background lifecycle, bonding,
   reconnect, mute, status, overflow, network policy, and local notifications.
2. **Memory controls:** history, correction/reanalysis, retention, deletion, API
   errors, and logout.
3. **Mobile experience:** approved information architecture, adaptive theme,
   onboarding, global status, screen states, search, correction UI, and tests.

Composio is a later adapter-backed workstream after the core beta gate passes.

## Device Reliability

### iOS Background Behavior

`Info.plist` includes `UIBackgroundModes` with `bluetooth-central`.
`FlutterBluePlus.setOptions(restoreState: true)` runs before the first
FlutterBluePlus API call. iOS may wake the app for BLE reads, writes, and
notifications and provides about 10 seconds of execution per wake event.

The app stores the selected `BluetoothDevice.remoteId` in SharedPreferences.
After first manual pairing it creates `BluetoothDevice.fromId(remoteId)` and uses
`connect(autoConnect: true, mtu: null)`. Every successful reconnect rediscovers
services, restores characteristic subscriptions, sends `SET_TIME`, then sends
`READY`. Android continues requesting MTU 247 after connection; iOS negotiates
MTU automatically.

A forced user termination is not recoverable by design. OS termination and
locked-screen operation are supported through CoreBluetooth restoration, subject
to the plugin/runtime limits. If `flutter_blue_plus` state restoration proves
insufficient in a release build, a narrow fork or native CoreBluetooth bridge is
allowed; this is an explicit hardware acceptance risk.

### Connection State

The app exposes these states through a single `DeviceConnectionState` model:

- unpaired;
- bluetoothOff;
- scanning;
- connecting;
- bonding;
- listening;
- muted;
- reconnecting;
- offline;
- error.

First pairing is manual. Later launches reconnect automatically. Reconnect delays
are 0, 2, 5, 10, and then 30 seconds while Bluetooth is available. Generic scan
is used only for first pairing. Recovery scans use the Echo service UUID.

### Bonding and Encryption

The wearable enables BLE Secure Connections with bonding and no input/output.
The first controlled pairing uses Just Works. The audio characteristic requires
encrypted reads/notifications; the control characteristic requires encrypted
reads/notifications/writes. The wearable accepts one bonded peer. Unbonded peers
cannot subscribe to audio or send control commands.

`Forget wearable` is initiated from the bonded app. It sends an encrypted
`FORGET_BOND` command, waits for acknowledgement, clears the mobile remote ID,
and returns both sides to pairing mode. If the paired phone is unavailable, the
beta recovery path is a full firmware/NVS erase over USB.

### Protocol Additions

Existing frame values remain unchanged. New control frames are:

- `SET_MUTED` (`0x15`): one payload byte, `0` listening and `1` muted;
- `FORGET_BOND` (`0x16`): no payload;
- `FORGET_BOND_OK` (`0x17`): firmware acknowledgement.

`DEVICE_STATUS` (`0x20`) becomes version 2 with 14 bytes:

| Offset | Type | Meaning |
|---|---|---|
| 0 | u8 | frame type `0x20` |
| 1 | u8 | status version `2` |
| 2 | u8 | flags: bit 0 muted, bit 1 overflow since last status |
| 3 | u8 | battery percent, `255` when unavailable |
| 4 | u16 LE | buffered Segment count |
| 6 | u32 LE | buffer bytes used |
| 10 | u32 LE | total dropped Segment count since boot |

`DEVICE_INFO` (`0x21`) has five bytes: frame type, protocol version, firmware
major, minor, and patch.

### Persistent Mute

Firmware stores `muted` in ESP32 Preferences/NVS. On `SET_MUTED=1`, firmware:

- persists the state;
- discards any in-progress Segment and pre-buffer;
- stops reading microphone frames;
- continues BLE and buffered-Segment upload;
- emits `DEVICE_STATUS`.

On reboot, muted remains active. Only an encrypted `SET_MUTED=0` command resumes
capture. The current GPIO mute code remains unused in the beta and does not
override app state.

### PSRAM Overflow

When a completed Segment will not fit, firmware drops oldest buffered Segments
until enough contiguous capacity exists. If the oldest Segment is the active
transfer, the transport is cancelled before dropping it. Each drop increments a
monotonic counter and sets the overflow status flag. The newest Segment is then
stored. Existing `UPLOAD_OK` remains the only normal dequeue path.

The mobile app shows an immediate warning with the number of lost Segments and
schedules a local notification if backgrounded.

### Notifications

The app requests notification permission during onboarding. It schedules local
notifications for:

- wearable disconnected for two minutes;
- dropped audio or buffer-critical status;
- repeated backend upload failure;
- external action requiring confirmation.

Reconnect cancels the pending disconnect notification. Normal transcript
completion does not notify. Daily summary notification is optional and off by
default.

### Network Policy

Cellular upload is enabled by default. A Wi-Fi-only setting blocks new HTTP
uploads while the network is not Wi-Fi; the wearable retains unacknowledged
Segments. `connectivity_plus` supplies connection type changes.

Public iOS APIs do not expose reliable roaming state. Echo therefore cannot
promise automatic roaming detection. The beta exposes cellular on/off and links
to iOS cellular settings; roaming control remains governed by the system.

## Memory Controls

### Chat History

The mobile API parses `GET /api/chat-sessions/{id}` into typed messages and loads
the full session into Ask. Selecting a session restores messages, title, IDs,
message indexes, and follow-up context. Deletion requires confirmation. Past
messages are immutable.

### Transcript and Speaker Correction

Authenticated endpoint:

`PATCH /api/segments/{segment_id}/transcription`

Request:

```json
{
  "text": "corrected text",
  "speaker": "self"
}
```

`text` is required and non-empty. `speaker` is `self`, `other`, or `unknown`.
The endpoint verifies ownership, records the previous text/speaker in a
`transcription_edits` audit table, updates the transcription and Segment, marks
the Conversation `analysis_status="reprocessing"`, and enqueues
`queue:reanalysis`.

Reanalysis rebuilds all chunks and conversation-scoped entities for the affected
Conversation from its current transcriptions. It updates embeddings and summary
but explicitly skips integration triggers and Rules. The implementation must not
call `trigger_integrations()` or `evaluate_rules()` on this path.

Because existing entity consolidation has limited provenance, reanalysis is
restricted to entities whose `conversation_id` matches the affected Conversation.
Cross-conversation entity consolidation is not reversed in this beta; this
limitation is visible in diagnostics and covered by regression tests.

### Audio Retention

The retention worker uses two cutoffs:

- completed audio: delete after 24 hours;
- pending/processing/failed audio: delete after 7 days.

Segment rows, transcriptions, entities, and embeddings remain. Cleanup runs every
six hours in batches of 100 and clears `audio_path` and `audio_size_bytes` after
file deletion.

### Conversation Deletion

`DELETE /api/conversations/{conversation_id}` verifies ownership and deletes:

- audio files;
- Segments;
- Transcriptions;
- Chunks;
- conversation-scoped Entities;
- the Conversation.

Database migration changes Segment→Conversation and Entity→Conversation foreign
keys to `ON DELETE CASCADE`. External actions already executed are not reversed.
The app warns about this before confirmation.

### API Errors and Logout

Mobile HTTP uses a single injected `http.Client`, a 10-second default timeout,
and typed `ApiException` values: unauthorized, timeout, offline, server,
validation, and unknown. UI never displays raw response bodies. Idempotent GETs
may retry once after a short delay; mutations do not retry except existing BLE
segment upload logic.

Logout clears API key, server URL, saved remote ID, connection policy, and local
chat state, disconnects BLE, and returns to onboarding. Static backend API keys
have no server logout endpoint.

## Mobile Experience

The implementation follows the approved mock reference in
`docs/mockups/echo-mobile/`.

### Navigation

Primary tabs remain:

- Today;
- Transcripts;
- Ask.

Settings is secondary navigation. Rules and Integrations remain under Settings.
Voice input is part of Ask rather than a separate tab.

### Global Status

A compact status component is visible across primary screens. Healthy listening
collapses to a small green indicator. Connecting, reconnecting, muted, Bluetooth
off, offline, loss, and error states expand into an actionable banner. Tapping it
opens Device detail.

### Today

Order is:

1. wearable status or required attention;
2. latest transcript;
3. open tasks;
4. daily summary;
5. fixed thumb-zone Pause/Resume control.

Technical statistics are available only in Diagnostics.

### Transcripts

The screen groups rows by Today, Yesterday, and date. Search is always available.
Rows show time, text, status, and cautious speaker label. Detail supports text
edit, speaker correction, and complete Conversation deletion.

### Ask

Text and voice share one composer. Empty state shows useful suggestions. Full
session history is loadable and resumable. Sources are expandable. External
action confirmation cards are visually reserved but not activated until the
Composio phase.

### Settings

Root sections are Device, Connection, Privacy, Automations, Diagnostics, and
About. Each opens a focused page. Logout lives in About. Rules and Integrations
remain available, but unsupported direct providers are hidden when the later
Composio adapter replaces them.

### Onboarding

Four steps:

1. validate server URL and API key;
2. explain/request Bluetooth, notification, background, and voice-query
   microphone permissions;
3. scan, pair, bond, save the wearable;
4. show listening/mute behavior and finish.

### Theme and Language

UI copy is English. The app follows system light/dark mode. It uses neutral
surfaces, restrained signal blue, green for healthy state, amber for attention,
and red for privacy/error. No decorative AI gradients or glass effects.

## Composio Phase

After the core beta gate passes, Echo adds a provider adapter for Composio under
the free plan. Initial apps are Google Calendar, Gmail, Todoist, Notion, and
Slack plus searchable additional apps. Audio and complete transcripts are never
sent. Tagging and local actions may run automatically; task/event/note creation
requires an explicit Rule; email, messages, edits, and deletions require in-app
confirmation. Every action has an audit record.

## Verification

Automated verification includes:

- native firmware tests for protocol, mute persistence, encrypted control,
  overflow, dropped count, and transfer cancellation;
- backend integration tests for ownership, audit edits, no-side-effect
  reanalysis, retention, cascade deletion, and chat history;
- Dart unit tests for reconnect backoff, state restoration boundaries, network
  policy, notification scheduling, API errors, logout, and models;
- Flutter widget tests for onboarding, global status states, Today mute,
  transcript search/edit/delete, Ask history, Settings hierarchy, and adaptive
  theme;
- iOS release build and Android debug build.

Manual verification uses the two-hour matrix in Success Criteria. Background
behavior is tested on a directly installed iOS release build without debugger or
USB connection. The 12-hour battery test is tracked separately.
