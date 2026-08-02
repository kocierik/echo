# BLE Latency and Reliability Design

## Goal

Reduce foreground BLE relay latency for a six-second ADPCM Segment to about five
seconds or less after speech ends under normal Android conditions, while ensuring
that malformed transfers and failed backend uploads never dequeue wearable data.

This design refines the existing BLE relay. It does not add background relay,
Wi-Fi fallback, persistent storage, bonding, or a dedicated FreeRTOS transfer
task.

## Firmware Pipeline

The capture format remains 16 kHz, 16-bit mono PCM encoded as IMA-ADPCM at about
8 KB/s. Maximum Segment duration becomes 6000 ms. Speech ends after 25 silent
32 ms frames, approximately 800 ms. The existing 500 ms pre-buffer remains, but
the frame that triggers speech start is encoded only once.

CRC32 is accumulated as each ADPCM frame is produced. The final CRC is stored in
the `BufferedSegment` header in PSRAM. BLE transport reads this stored value and
does not scan the Segment after recording.

The preferred and maximum transport MTU is 247. A data notification therefore
contains at most 237 ADPCM bytes after ATT and Echo protocol headers.

`BleTransport::update()` may send multiple sequential chunks per invocation. It
stops when any of these conditions is met:

- the current 32-chunk ACK window is complete;
- NimBLE refuses a notification;
- 3000 microseconds have elapsed in the current update;
- the Segment has no more chunks.

This keeps BLE work bounded so the microphone DMA is serviced every 32 ms. The
ACK timeout and restart semantics remain unchanged. The event queue is drained
within the same time budget instead of processing one event per audio frame.

Firmware logging is limited to connection/MTU changes, Segment start/completion,
window acknowledgement, restart, upload acceptance, and errors. It does not log
each chunk or each successful notification.

## Mobile Pipeline

Android requests MTU 247 after connection. iOS relies on automatic MTU
negotiation. Linux and other desktop targets skip an explicit request. Failure to
request the Android MTU is visible but does not disconnect the device.

Protocol parsing moves into a pure Dart packet assembler. It owns:

- protocol version and frame-length validation;
- Segment ID and metadata tracking;
- contiguous sequence validation;
- expected byte length and chunk count validation;
- CRC32 validation;
- immutable completed-Segment output.

A missing, unexpected duplicate, out-of-order, wrong-ID, wrong-length, or
wrong-CRC frame resets the assembler and produces `RESTART_SEGMENT`. No malformed
bytes reach the backend.

The assembler emits cumulative ACK events every 32 chunks and at the final
chunk. Control writes are serialized so the final ACK completes before backend
upload and `UPLOAD_OK` cannot overtake it.

The completed Segment preserves firmware duration, recorded-at time,
silence-before duration, and average energy. These values are passed unchanged to
`ApiService.uploadSegment`.

Only a returned value of `true`, representing backend HTTP 201, permits
`UPLOAD_OK`. A returned `false`, exception, or timeout retains the completed
Segment in the app and retries while the app remains foreground and connected.
Retry delays are 2, 5, 10, and then 30 seconds. A disconnect cancels the local
retry; the wearable retains and retransmits the Segment after reconnection.

BLE scan, audio, control, connection-state, and retry subscriptions are owned and
cancelled explicitly. UI progress is throttled to at most four updates per
second. Per-chunk SnackBars and logging are removed.

## Hardware Feedback

The XIAO user LED is treated as active-low through named `LED_ON` and `LED_OFF`
values. Button debounce tracks separate raw and stable states so one stable
active-low press toggles mute exactly once.

## Observability

Both sides log timestamped phase transitions rather than packet traffic:

- VAD speech end;
- Segment stored in PSRAM;
- BLE transfer start and completion;
- backend upload start and HTTP response;
- firmware receipt of `UPLOAD_OK`.

These markers distinguish capture/VAD, BLE, HTTP, and backend worker latency.

## Tests

Native firmware tests cover CRC accumulation equivalence, stored CRC metadata,
32-chunk windows, bounded burst decisions, timeout/restart behavior, and the
existing dequeue invariant.

Flutter tests cover successful assembly, each malformed-transfer condition,
ACK cadence, metadata preservation, serialized control writes, HTTP 201,
non-201, exception, timeout, retry, and disconnect cancellation.

PlatformIO and Flutter builds/tests run on the development machine, not the work
PC. Hardware acceptance uses Android first and then iOS:

1. Confirm negotiated MTU in logs.
2. Relay six seconds of speech and measure every phase marker.
3. Confirm backend receipt within about five seconds after VAD speech end under
   normal conditions.
4. Interrupt BLE mid-transfer and verify restart without dequeue.
5. Return a backend non-201 response and verify no `UPLOAD_OK` or dequeue.
6. Corrupt or omit a test packet and verify `RESTART_SEGMENT`.

The binding invariant remains: the wearable dequeues a Segment only after a
matching `UPLOAD_OK` generated from backend HTTP 201 for a fully validated
transfer.