# BLE Latency and Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver validated six-second audio Segments to the backend within about five seconds after speech ends under normal Android BLE conditions, without dequeueing on malformed data or failed uploads.

**Architecture:** Accumulate CRC while encoding, store it with Segment metadata, and send bounded BLE bursts from the existing loop. A pure Dart assembler validates the wire protocol, while a relay controller serializes ACK/upload decisions and retries HTTP independently from FlutterBlue.

**Tech Stack:** PlatformIO native/Arduino tests, NimBLE-Arduino, Flutter/Dart, flutter_blue_plus, flutter_test

## Global Constraints

- Keep transport BLE-only and foreground-only.
- Use MTU 247, 32-chunk ACK windows, 3000 microsecond firmware burst budget, 6000 ms maximum Segment duration, and 25 silent frames.
- Never dequeue before matching `UPLOAD_OK` generated from backend HTTP 201 for a fully validated Segment.
- Preserve `/api/segments` and its multipart contract.
- Do not add a FreeRTOS transfer task, Wi-Fi fallback, background service, persistence, bonding, or new runtime dependencies.
- Write tests on this PC but do not run or install PlatformIO/Flutter here; record exact verification commands for the development machine.

---

### Task 1: Firmware CRC and Segmentation

**Files:**
- Modify: `firmware/src/config.h`
- Modify: `firmware/src/main.ino`
- Modify: `firmware/src/psram_buffer.h`
- Modify: `firmware/src/ble_transport.h`
- Modify: `firmware/test/test_ble_protocol/test_main.cpp`
- Modify: `firmware/test/test_ble_transport_contract/test_main.cpp`

**Interfaces:**
- `BufferedSegment` gains `uint32_t crc`.
- `PSRAMBuffer::store(...)` accepts the completed CRC.
- `BleTransport` reads stored CRC and performs no post-recording CRC scan.

- [ ] Write source-contract and CRC-equivalence tests that fail while transport still owns `_crcOffset`/`CRC_BYTES_PER_UPDATE` and while the buffer header lacks CRC.
- [ ] Set Segment duration to 6000 ms and silent-frame threshold to 25.
- [ ] Initialize the per-Segment CRC accumulator when speech starts, update it after each encoded ADPCM frame, finalize it once, and store it with metadata.
- [ ] Avoid encoding the VAD trigger frame twice by excluding the current frame from the pre-buffer replay or not encoding it a second time.
- [ ] Remove the transport CRC pre-pass and use `BufferedSegment::crc` in `SEGMENT_START`.
- [ ] Verify on development machine: `cd firmware && pio test -e native && pio run -e xiao_esp32s3`.

### Task 2: Firmware Bounded Burst Transport

**Files:**
- Modify: `firmware/src/config.h`
- Modify: `firmware/src/ble_transfer_state.h`
- Modify: `firmware/src/ble_transport.h`
- Modify: `firmware/test/test_ble_transfer_state/test_main.cpp`
- Modify: `firmware/test/test_ble_protocol/test_main.cpp`

**Interfaces:**
- `BleTransferState::WINDOW_SIZE` is 32.
- `BleTransport::update()` drains pending control events and sends chunks until window completion, notification failure, completion, or 3000 microseconds.
- Preferred/effective MTU is 247.

- [ ] Update failing tests to require 32 chunks before `WAITING_ACK` and payload size 237 at MTU 247.
- [ ] Add a pure burst-decision helper or state tests proving stop conditions without NimBLE.
- [ ] Drain queued events within the same 3000 microsecond budget.
- [ ] Send preamble/chunks in a bounded loop; stop immediately on failed notify and retain current sequence.
- [ ] Remove per-notification/backoff-loop logging; retain phase/error logs.
- [ ] Verify with native tests and XIAO build on the development machine.

### Task 3: Pure Dart Packet Assembler

**Files:**
- Create: `mobile/lib/services/ble_packet_assembler.dart`
- Create: `mobile/test/services/ble_packet_assembler_test.dart`
- Modify: `mobile/lib/services/ble_service.dart`

**Interfaces:**
- `BleCompletedSegment` contains Segment ID, ADPCM bytes, recorded-at UTC, duration, silence-before, and energy.
- `BlePacketAssembler.add(List<int>)` returns typed events: progress/ACK, completed, or restart-required.
- The assembler has no FlutterBlue or HTTP dependency.

- [ ] Write failing tests for valid transfer, version/frame length, wrong ID, missing/out-of-order/duplicate sequence, expected length/chunk count, CRC mismatch, metadata, ACK at 32 and final chunk, and reset.
- [ ] Implement explicit little-endian parsing and CRC32 matching firmware.
- [ ] Reject malformed input and clear partial bytes before returning restart-required.
- [ ] Replace ad hoc `_segmentBuffer` parsing in `BleService` with assembler events.
- [ ] Verify on development machine: `cd mobile && flutter test test/services/ble_packet_assembler_test.dart`.

### Task 4: Reliable Mobile Relay

**Files:**
- Create: `mobile/lib/services/ble_relay_controller.dart`
- Create: `mobile/test/services/ble_relay_controller_test.dart`
- Modify: `mobile/lib/services/ble_service.dart`
- Modify: `mobile/lib/services/api_service.dart`

**Interfaces:**
- Relay controller accepts completed Segments, an upload function, and a serialized control-write function.
- It sends `UPLOAD_OK` only after `uploadSegment` returns true.
- Retry delays are 2, 5, 10, then 30 seconds and stop on disconnect/dispose.

- [ ] Write failing tests for ACK serialization, true/false upload, exception, timeout, retry schedule, duplicate completion, and disconnect cancellation.
- [ ] Implement a serialized control-write chain so final ACK precedes upload and `UPLOAD_OK`.
- [ ] Implement one active upload/retry per Segment; retain bytes until success or disconnect.
- [ ] Add an HTTP timeout and preserve the boolean non-201 result.
- [ ] Pass firmware duration, recorded-at, silence, and energy unchanged to `uploadSegment`.
- [ ] On Android only, request MTU 247; on iOS/Linux skip explicit request. MTU request failure is logged once and does not abort connection.
- [ ] Own and cancel scan, audio, control, connection, and retry subscriptions.
- [ ] Verify focused tests and `flutter analyze` on the development machine.

### Task 5: UI Logging and Hardware Feedback

**Files:**
- Modify: `mobile/lib/services/ble_service.dart`
- Modify: `mobile/lib/screens/home_screen.dart`
- Modify: `mobile/lib/screens/device_messages_screen.dart`
- Modify: `firmware/src/indicators.h`
- Create: `firmware/test/test_indicator_state/test_main.cpp`

**Interfaces:**
- UI receives phase/error messages throttled to at most four per second, not chunk messages.
- Indicator logic uses separate raw/stable button state and active-low LED constants.

- [ ] Add a pure debounce state helper and native tests for one toggle per stable press, bounce rejection, and release/repress.
- [ ] Implement active-low LED values and corrected debounce behavior.
- [ ] Remove per-chunk firmware/mobile prints and per-window SnackBars; expose transfer start, completion, HTTP result, restart, and errors.
- [ ] Store and cancel the `DeviceMessagesScreen` subscription.
- [ ] Keep progress UI stable and throttled to 250 ms minimum intervals.
- [ ] Verify native tests plus Flutter tests/analysis on the development machine.

### Task 6: Static Review and Hardware Verification Handoff

**Files:**
- Modify only if review finds a defect in the touched scope.

**Interfaces:**
- Produces a clean cross-language protocol and exact commands/results expected on the development machine.

- [ ] Compare every firmware frame size, endian field, window value, CRC polynomial, and MTU payload against Dart constants/tests.
- [ ] Run workspace diagnostics and `git diff --check` on this PC.
- [ ] On development machine run `pio test -e native`, XIAO build/upload, `flutter test`, and `flutter analyze`.
- [ ] Measure logs for VAD end, BLE completion, HTTP 201, and `UPLOAD_OK` using a six-second Segment.
- [ ] Exercise BLE interruption, malformed packet, and backend non-201; verify no premature dequeue.