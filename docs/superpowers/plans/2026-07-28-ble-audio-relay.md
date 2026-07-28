% BLE audio relay — Piano (2026-07-28)

Obiettivo
-------
Progettare e implementare un "BLE audio relay" che permetta a un dispositivo con risorse limitate (p.es. microcontroller con PSRAM) di inviare flussi audio via BLE a un gateway/relay che li inoltra a un backend o a un altro endpoint locale. Il relay minimizza latenza, preserva qualità sufficiente per riconoscimento vocale e analisi, e gestisce connessioni intermittenti.

Contesto e motivazione
---------------------
- Uso previsto: dispositivi embedded che catturano audio, comprimono (ADPCM) e lo trasmettono via BLE a un telefono o a un gateway.
- Vincoli: memoria limitata, banda BLE variabile, consumo energetico critico, latenza target < 300 ms end-to-end quando possibile.

Scope
-----
- Inclusi: protocolli di frammentazione e ricostruzione, buffering e jitter handling, handoff tra relay, meccanismi di rivelazione e ritrasmissione di frame persi, test end-to-end.
- Esclusi: integrazione con cloud provider specifici (da definire in iterazioni successive), supporto a codec multipli oltre ADPCM iniziale.

Milestones
----------
1. Definizione dei requisiti funzionali e non funzionali (questa versione)
2. Specifica di design e API locali (file spec)
3. Prototipo funzionante: dispositivo -> gateway BLE relay -> backend (simulazione)
4. Test di latenza, qualità e resilienza (suite automatizzata)
5. Ottimizzazioni consumo e memoria, edge cases
6. Documentazione operativa e piano di rollout

Task dettagliati e stime (T-shirt sizing)
--------------------------------------
- Requisiti & acceptance criteria — 1 giorno
- Spec di design completa — 1-2 giorni
- Implementazione relay minimale (server + buffer) — 3 giorni
- Client firmware/integrazione ADPCM (invio fragm.) — 2 giorni
- Test e tuning latenza/throughput — 2 giorni
- CI + test end-to-end automatizzati — 2 giorni
- Revisione e piccolo refactor — 1 giorno

Dipendenze
----------
- Librerie ADPCM esistenti (codificatore/decodificatore nel repo)
- Ambiente di test: `simulator/` e `simulator/adpcm_encode.py`
- Hardware per validazione reale (opzionale, per fase finale)

Metriche di successo
--------------------
- End-to-end latency median < 300 ms (bulk of samples)
- Packet/frame loss gestito senza caduta della sessione > 99% delle volte
- CPU/Memory fit su target device (uso PSRAM controllato)

Rischi e mitigazioni
--------------------
- BLE throughput variabile: implementare adattamento bitrate e frammentazione adattiva.
- Spike di latenza: buffer jitter e priorità per pacchetti critici.
- Disconnessioni frequenti: ripristino di stato e retransmit dei frame critici.

Prossimi passi
-------------
- Convalidare il design nella specifica: `docs/superpowers/specs/2026-07-28-ble-audio-relay-design.md`
- Avviare implementazione prototipo gateway e test con `simulator/adpcm_encode.py`
# BLE Audio Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace direct wearable Wi-Fi upload with a reliable foreground BLE relay through the Android/iOS Flutter app.

**Architecture:** The wearable stores every completed ADPCM Segment in PSRAM, transfers the oldest entry through a sequenced GATT protocol, and dequeues only after the app receives HTTP 201 from the backend and writes `UPLOAD_OK`. Pure C++ and Dart protocol components remain independent from NimBLE, FlutterBlue, and HTTP so failure behavior can be tested without hardware.

**Tech Stack:** PlatformIO, Arduino ESP32-S3, NimBLE-Arduino, C++ Unity tests, Flutter/Dart, flutter_blue_plus, flutter_test

## Global Constraints

- Firmware transport is BLE-only; do not retain Wi-Fi or HTTP fallback in `main.ino`.
- Android and iOS relay only while the Echo app is open.
- Keep the existing service and characteristic UUIDs.
- Never call `PSRAMBuffer::dequeue()` before a matching `UPLOAD_OK` produced after backend HTTP 201.
- Keep `/api/segments` and its multipart contract unchanged.
- Keep the invalid `default_16MB.csv` override removed; use the board's official 8 MB default.
- Do not add BLE bonding, background services, OTA, or persistent storage in this implementation.

---

### Task 1: Binary BLE Protocol

**Files:**
- Create: `firmware/src/ble_protocol.h`
- Create: `firmware/test/test_ble_protocol/test_main.cpp`
- Modify: `firmware/platformio.ini`

**Interfaces:**
- Produces: `EchoBleProtocol` frame constants, little-endian read/write helpers, `crc32(const uint8_t*, size_t)`, and frame encode/decode functions.
- Consumes: only standard integer and byte types; no Arduino BLE APIs.

- [ ] **Step 1: Add a native PlatformIO test environment**

Add an `[env:native]` environment using `platform = native`, `test_framework = unity`, and `test_build_src = false`. Preserve the XIAO environment and its 8 MB board default.

- [ ] **Step 2: Write failing protocol tests**

Cover the known CRC32 vector `123456789 -> 0xCBF43926`, little-endian round trips, exact `SEGMENT_START` bytes, exact `SET_TIME` bytes, truncated control frames, and unknown frame types.

- [ ] **Step 3: Verify RED**

Run: `cd firmware && pio test -e native -f test_ble_protocol`

Expected: compilation fails because `ble_protocol.h` and its functions do not exist.

- [ ] **Step 4: Implement the minimal protocol header**

Define frame types `0x01`, `0x02`, `0x03`, `0x10` through `0x14`, and `0x20`. Encode/decode into caller-owned byte buffers with explicit bounds checks; do not use packed-struct pointer casts.

- [ ] **Step 5: Verify GREEN**

Run the same native test command and expect all protocol tests to pass.

### Task 2: Wrap-Safe Segment Buffer

**Files:**
- Create: `firmware/src/ring_buffer_layout.h`
- Create: `firmware/test/test_ring_buffer_layout/test_main.cpp`
- Modify: `firmware/src/psram_buffer.h`

**Interfaces:**
- Produces: `RingBufferLayout` with `reserve(size_t, size_t&)`, `frontOffset()`, `pop(size_t)`, `count()`, and `bytesUsed()`.
- Produces: `BufferedSegment` fields `segmentId`, `dataLength`, `durationMs`, `silenceBeforeMs`, `capturedAtMs`, and `avgEnergy`.
- Produces: `PSRAMBuffer::store(...)` accepting all protocol metadata and preserving FIFO order across wrap.

- [ ] **Step 1: Write failing layout tests**

Cover sequential reservations, wrap to zero, FIFO pop across the wrap boundary, rejection when the beginning lacks space, full-to-empty reset, and byte/count accounting.

- [ ] **Step 2: Verify RED**

Run: `cd firmware && pio test -e native -f test_ring_buffer_layout`

Expected: compilation fails because `ring_buffer_layout.h` does not exist.

- [ ] **Step 3: Implement `RingBufferLayout`**

Keep offset arithmetic separate from PSRAM allocation. Track the end-of-tail wrap boundary explicitly so `frontOffset()` jumps to zero only after the last pre-wrap entry is popped.

- [ ] **Step 4: Integrate layout and metadata into `PSRAMBuffer`**

Replace `_readPos`, `_writePos`, and ad hoc wrap logic with `RingBufferLayout`. Keep `peek()` non-destructive and `dequeue()` as the only removal method.

- [ ] **Step 5: Verify GREEN**

Run both native test filters and expect all tests to pass.

### Task 3: Firmware GATT Transport

**Files:**
- Create: `firmware/src/ble_transport.h`
- Create: `firmware/test/test_ble_transfer_state/test_main.cpp`
- Create: `firmware/src/ble_transfer_state.h`
- Modify: `firmware/platformio.ini`

**Interfaces:**
- Produces: pure `BleTransferState` window/ACK state machine.
- Produces: `BleTransport::begin()`, `BleTransport::update(PSRAMBuffer&)`, `BleTransport::isConnected()`, and `BleTransport::notifyBufferStatus(const PSRAMBuffer&)`.
- Consumes: `EchoBleProtocol`, `PSRAMBuffer`, and NimBLE-Arduino.

- [ ] **Step 1: Write failing transfer-state tests**

Cover READY gating, eight-frame windows, valid ACK advancement, stale/wrong Segment ACK rejection, ACK timeout restart, `RESTART_SEGMENT`, and `UPLOAD_OK` eligibility only after all chunks were acknowledged.

- [ ] **Step 2: Verify RED**

Run: `cd firmware && pio test -e native -f test_ble_transfer_state`

Expected: compilation fails because the state machine does not exist.

- [ ] **Step 3: Implement pure transfer state**

Model idle, waiting-ready, sending-window, waiting-ack, waiting-upload, and restart states. Expose decisions; keep NimBLE callbacks outside this class.

- [ ] **Step 4: Add NimBLE-Arduino dependency and transport**

Add a pinned `h2zero/NimBLE-Arduino` dependency to the XIAO environment. Advertise `Echo Wearable`, create the existing service/audio/control UUIDs, negotiate MTU-aware payloads, translate control writes into state-machine events, and emit status notifications.

- [ ] **Step 5: Enforce dequeue invariant**

In the control callback, accept `UPLOAD_OK` only for the active oldest Segment in waiting-upload state. Perform the sole transport-triggered `buffer.dequeue()` there, then advertise updated status.

- [ ] **Step 6: Verify state tests and firmware compilation**

Run native transfer tests, then `pio run -e xiao_esp32s3`. Expect all tests and firmware build to succeed.

### Task 4: BLE-Only Capture Pipeline

**Files:**
- Modify: `firmware/src/main.ino`
- Modify: `firmware/src/config.h`
- Modify: `firmware/src/psram_buffer.h`
- Create: `firmware/test/test_ble_transport_contract/test_main.cpp`

**Interfaces:**
- Consumes: `BleTransport`, `PSRAMBuffer`, VAD, ADPCM encoder, and app-provided time anchor.
- Produces: each finalized Segment stored once in PSRAM with a monotonic capture time and stable Segment ID.

- [ ] **Step 1: Add a compile-time transport assertion/test**

Add a native source-contract test that asserts `main.ino` no longer includes `WiFi.h`, `http_sender.h`, or `time_sync.h`, and does include `ble_transport.h`.

- [ ] **Step 2: Verify RED**

Run the contract test and expect it to fail on the existing Wi-Fi includes.

- [ ] **Step 3: Replace direct upload flow**

Remove Wi-Fi connect/reconnect, NTP, direct HTTP send, and Wi-Fi buffer flush. Initialize BLE after PSRAM. Always store finalized Segments, then let `BleTransport::update()` service the oldest entry while capture continues.

- [ ] **Step 4: Add time-anchor conversion**

Store capture `millis()` in each buffer entry. When `SET_TIME` arrives, retain Unix milliseconds plus device `millis()` anchor and derive each Segment's UTC timestamp at transfer time, including entries recorded before first connection.

- [ ] **Step 5: Verify contract and firmware build**

Run all native firmware tests and `pio run -e xiao_esp32s3`.

### Task 5: Pure Dart Packet Assembly

**Files:**
- Create: `mobile/lib/services/ble_packet_assembler.dart`
- Create: `mobile/test/services/ble_packet_assembler_test.dart`

**Interfaces:**
- Produces: immutable `BleCompletedSegment` with Segment ID, bytes, UTC recorded-at, duration, silence, and energy.
- Produces: assembler events for ACK window, restart required, and completed Segment.
- Consumes: raw characteristic byte lists only.

- [ ] **Step 1: Write failing Dart tests**

Cover normal start/metadata/data assembly, eight-frame ACK, missing sequence, duplicate sequence, wrong Segment ID, truncated frames, CRC mismatch, reset, and time metadata preservation.

- [ ] **Step 2: Verify RED**

Run: `cd mobile && flutter test test/services/ble_packet_assembler_test.dart`

Expected: compilation fails because the assembler does not exist.

- [ ] **Step 3: Implement the assembler**

Parse explicit little-endian fields with `ByteData`, reject malformed frames without partial completion, and return typed events instead of performing BLE writes or HTTP calls.

- [ ] **Step 4: Verify GREEN**

Run the focused Flutter test and expect all cases to pass.

### Task 6: Reliable Flutter BLE Service

**Files:**
- Modify: `mobile/lib/services/ble_service.dart`
- Modify: `mobile/lib/services/api_service.dart`
- Create: `mobile/test/services/ble_relay_controller_test.dart`
- Create: `mobile/lib/services/ble_relay_controller.dart`

**Interfaces:**
- Produces: `BleRelayController` that converts assembler events into control writes and backend upload decisions.
- Produces: `BleService` state stream including disconnected, scanning, connecting, connected, transferring, and error details.
- Consumes: `BlePacketAssembler`, FlutterBlue characteristics, and `ApiService.uploadSegment`.

- [ ] **Step 1: Write failing relay-controller tests**

Use fake control and upload ports. Cover HTTP 201 sending `UPLOAD_OK`, false/exception sending no final ACK, restart event sending `RESTART_SEGMENT`, ACK event writing the highest contiguous sequence, and duplicate completion not producing concurrent uploads.

- [ ] **Step 2: Verify RED**

Run the focused controller test and expect missing-type failures.

- [ ] **Step 3: Implement controller ports and behavior**

Keep FlutterBlue and HTTP behind injected function interfaces. Treat only `uploadSegment == true` as acceptance. Preserve the active Segment until the final control write succeeds.

- [ ] **Step 4: Integrate controller into `BleService`**

Replace the current unsequenced buffer logic. Subscribe before writing `SET_TIME` then `READY`, request MTU without assuming 512, listen to connection state with owned subscriptions, reconnect only while foreground and after user initiation, and surface exceptions.

- [ ] **Step 5: Verify controller and assembler tests**

Run both focused Flutter test files.

### Task 7: App Lifecycle and BLE UI

**Files:**
- Modify: `mobile/lib/main.dart`
- Modify: `mobile/lib/widgets/ble_indicator.dart`
- Modify: `mobile/android/app/src/main/AndroidManifest.xml`
- Modify: `mobile/ios/Runner/Info.plist`
- Create: `mobile/test/widgets/ble_indicator_test.dart`

**Interfaces:**
- Consumes: `BleService.stateStream`, scan/connect/disconnect methods, and transfer status.
- Produces: one app-session BLE service owned by `MainShell` and visible foreground status.

- [ ] **Step 1: Write failing indicator widget tests**

Cover labels/icons for disconnected, scanning, connecting, connected, transferring, and error states plus tap callback behavior.

- [ ] **Step 2: Verify RED**

Run the focused widget test and expect failures for missing transferring/error states.

- [ ] **Step 3: Extend indicator and own service in `MainShell`**

Create/dispose one service, subscribe with `setState` guarded by `mounted`, place the compact indicator in the app shell, initiate scan on tap, and show actionable SnackBars for permission, adapter, backend, and buffer errors.

- [ ] **Step 4: Handle app lifecycle**

Use `WidgetsBindingObserver`: pause reconnect attempts outside `AppLifecycleState.resumed`, resume scanning/reconnect only when the app returns and the user previously initiated connection.

- [ ] **Step 5: Correct platform permissions**

On Android, set `android:maxSdkVersion="30"` on `BLUETOOTH`,
`BLUETOOTH_ADMIN`, and `ACCESS_FINE_LOCATION`; declare `BLUETOOTH_SCAN` with
`android:usesPermissionFlags="neverForLocation"`; and declare
`BLUETOOTH_CONNECT` without an SDK cap. On iOS, retain Bluetooth usage
descriptions and do not add background modes.

- [ ] **Step 6: Verify UI and static analysis**

Run the widget test and `flutter analyze`.

### Task 8: Full Verification and Hardware Acceptance

**Files:**
- Modify only if a focused verification exposes a defect in the touched slice.

**Interfaces:**
- Consumes: completed firmware and mobile relay.
- Produces: fresh build, test, and hardware evidence.

- [ ] **Step 1: Run all firmware native tests**

Run: `cd firmware && pio test -e native`

- [ ] **Step 2: Build XIAO firmware**

Run: `cd firmware && pio run -e xiao_esp32s3`

Confirm the build uses 8 MB flash and succeeds.

- [ ] **Step 3: Run Flutter tests and analysis**

Run: `cd mobile && flutter test && flutter analyze`

- [ ] **Step 4: Build both mobile targets**

Run Android debug build. Run iOS build without codesigning on macOS.

- [ ] **Step 5: Execute hardware matrix**

Verify normal relay, mid-transfer Bluetooth interruption, backend outage/recovery, disconnect after HTTP acceptance, and multiple queued Segments delivered FIFO.

- [ ] **Step 6: Inspect dequeue evidence**

Capture serial logs proving no dequeue occurs before matching `UPLOAD_OK`, including all failure scenarios.