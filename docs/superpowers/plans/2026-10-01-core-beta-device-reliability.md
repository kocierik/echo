# Core Beta Device Reliability Implementation Plan

> **Stato (13/10/2026): implementato** — commit 265f971. Le checkbox qui sotto non sono state aggiornate durante l'implementazione; lo stato attuale è in [PROJECT-STATUS.md](../../PROJECT-STATUS.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one bonded Echo wearable relay audio reliably to one iPhone while foregrounded, backgrounded, or locked, with automatic reconnect, persistent mute, observable status, and oldest-first overflow.

**Architecture:** Firmware extends the existing encrypted GATT protocol and owns durable privacy/buffer state. Flutter owns pairing identity, CoreBluetooth restoration, network policy, notifications, and a single global device state model. The existing ACK/CRC/UPLOAD_OK invariant remains unchanged.

**Tech Stack:** PlatformIO/Arduino ESP32-S3, NimBLE-Arduino 2.3.2, Flutter/Dart, flutter_blue_plus, SharedPreferences, flutter_local_notifications-compatible plugin, connectivity_plus-compatible plugin.

## Global Constraints

- iOS-first; Android must still compile but Android background parity is not required.
- Support foreground, background, and locked screen; forced user termination is excluded.
- One bonded iPhone and one wearable.
- Existing BLE UUIDs, audio frame values, MTU 247, CRC, ACK, and UPLOAD_OK semantics remain compatible.
- No audio dequeue without matching UPLOAD_OK after backend HTTP 201.
- Muted survives reboot and stops all new microphone reads while BLE remains active.
- On overflow, drop oldest buffered Segment, increment loss count, then store newest.
- Cellular upload is default; Wi-Fi-only is optional. Automatic roaming detection is not claimed.
- Do not add backend device-pairing or device-status tables.
- Do not implement microSD, physical mute, battery sensing, sleep optimization, or Android foreground service.
- Pin dependency versions that compile with the Mac's installed Flutter/Xcode toolchain; do not use unconstrained latest versions.

---

### Task 1: Toolchain and Plugin Compatibility Gate

**Files:**
- Modify: `mobile/pubspec.yaml`
- Modify: `mobile/ios/Podfile` if present after Flutter regeneration
- Test: `mobile/test/services/ble_background_capability_test.dart`

**Interfaces:**
- Produces: one pinned `flutter_blue_plus` version exposing `FlutterBluePlus.setOptions(restoreState: true)`.
- Produces: pinned local-notification and connectivity packages compatible with the installed Flutter/Xcode versions.

- [ ] **Step 1: Record the development toolchain**

Run on the Mac:

```bash
flutter --version
dart --version
xcodebuild -version
cd mobile && flutter pub outdated
```

Save the output in the task report, not the repository.

After `flutter pub get`, inspect the resolved package source before writing the
probe:

```bash
grep -R "restoreState\|setOptions\|BluetoothDevice.fromId" \
  "$HOME/.pub-cache/hosted/pub.dev/flutter_blue_plus-"*/lib
```

Expected: all three APIs are present in the resolved source. If any is absent,
test the lowest newer stable release that provides it and still compiles with
the recorded Flutter/Xcode toolchain.

- [ ] **Step 2: Prove background restoration API availability**

Create `mobile/test/services/ble_background_capability_test.dart`:

```dart
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flutter_blue_plus exposes restoreState configuration', () {
    expect(
      () => FlutterBluePlus.setOptions(restoreState: true),
      returnsNormally,
    );
  });
}
```

Run:

```bash
cd mobile
flutter test test/services/ble_background_capability_test.dart
```

Expected: compile/pass. If current `1.32.x` does not expose `restoreState`, upgrade only `flutter_blue_plus` to the lowest stable version that does and repeat. Record its personal-use license before continuing.

- [ ] **Step 3: Add compatible notification/connectivity packages**

Run `flutter pub add` without accepting a toolchain upgrade. For each package,
start with the newest release accepted by the recorded SDK, then step back only
when `pub get` or the focused build fails. Replace all three caret constraints
with the exact numeric versions shown by `flutter pub deps`; the committed
`pubspec.yaml` must contain no ranges or provisional version text.

Expected: `flutter pub get`, the capability test, and `flutter analyze` pass with the current toolchain.

- [ ] **Step 4: Commit**

```bash
git add mobile/pubspec.yaml mobile/test/services/ble_background_capability_test.dart
git commit -m "chore: pin mobile background dependencies"
```

### Task 2: Protocol V2 Device Status and Controls

**Files:**
- Modify: `firmware/src/ble_protocol.h`
- Modify: `firmware/test/test_ble_protocol/test_main.cpp`
- Create: `mobile/lib/services/device_protocol.dart`
- Create: `mobile/test/services/device_protocol_test.dart`

**Interfaces:**
- Produces firmware constants: `FRAME_SET_MUTED=0x15`, `FRAME_FORGET_BOND=0x16`, `FRAME_FORGET_BOND_OK=0x17`, `FRAME_DEVICE_INFO=0x21`.
- Bumps `PROTOCOL_VERSION` from 1 to 2 and `DEVICE_STATUS_SIZE` from 8 to 14; existing audio-frame layouts remain unchanged.
- Produces `DeviceStatus` with `muted`, `overflowed`, `batteryPercent`, `bufferCount`, `bufferBytes`, and `droppedSegments`.
- Produces `DeviceInfo(protocolVersion, major, minor, patch)`.

- [ ] **Step 1: Write failing C++ byte-vector tests**

Add exact vectors:

```cpp
void test_device_status_v2_exact_bytes() {
    uint8_t bytes[14] = {};
    TEST_ASSERT_EQUAL_UINT32(14, EchoBleProtocol::encodeDeviceStatusV2(
        true, true, 255, 3, 12000, 7, bytes, sizeof(bytes)));
    const uint8_t expected[] = {
        0x20, 0x02, 0x03, 0xFF, 0x03, 0x00,
        0xE0, 0x2E, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00};
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, bytes, sizeof(expected));
}
```

Run `cd firmware && pio test -e native -f test_ble_protocol`; expect compile failure for the missing encoder.

- [ ] **Step 2: Implement firmware codecs**

Implement fixed-size explicit little-endian encoders/decoders; never cast packed structs. Keep old audio frames unchanged.

- [ ] **Step 3: Write failing Dart parser tests**

```dart
test('parses device status v2', () {
  final status = DeviceProtocol.parseStatus(Uint8List.fromList([
    0x20, 0x02, 0x03, 0xff, 0x03, 0x00,
    0xe0, 0x2e, 0, 0, 0x07, 0, 0, 0,
  ]));
  expect(status.muted, isTrue);
  expect(status.overflowed, isTrue);
  expect(status.batteryPercent, isNull);
  expect(status.droppedSegments, 7);
});
```

- [ ] **Step 4: Implement pure Dart protocol**

`device_protocol.dart` has no FlutterBlue dependency and returns typed parse errors for bad type/version/length.

- [ ] **Step 5: Verify and commit**

```bash
cd firmware && pio test -e native -f test_ble_protocol
cd ../mobile && flutter test test/services/device_protocol_test.dart
git add firmware/src/ble_protocol.h firmware/test/test_ble_protocol mobile/lib/services/device_protocol.dart mobile/test/services/device_protocol_test.dart
git commit -m "feat: define wearable status and privacy protocol"
```

### Task 3: Persistent Mute

**Files:**
- Create: `firmware/src/device_preferences.h`
- Create: `firmware/src/mute_state.h`
- Modify: `firmware/src/main.ino`
- Modify: `firmware/src/ble_transport.h`
- Modify: `firmware/src/ble_transport_events.h`
- Test: `firmware/test/test_mute_state/test_main.cpp`

**Interfaces:**
- Produces `MuteState::setMuted(bool)` and `MuteState::isMuted()`.
- `DevicePreferences` stores NVS key `privacy/muted`.
- `BleTransport` invokes a provided mute command callback on `FRAME_SET_MUTED`.

- [ ] **Step 1: Write failing pure mute-state tests**

Test listening→muted, muted→listening, duplicate commands, and boot from persisted true. The pure class accepts `load` and `save` function objects so native tests do not include Arduino Preferences.

- [ ] **Step 2: Implement NVS adapter and state**

Use `Preferences.begin("privacy", false)`, `getBool("muted", false)`, and `putBool`. Persistence failure keeps the in-memory state and emits a status error.

- [ ] **Step 3: Integrate capture semantics**

On transition to muted: discard `segmentPos`, reset VAD/encoder/pre-buffer, turn recording LED off, and skip `audio.readSamples`. Buffered completed Segments continue uploading. On unmute: reset VAD/pre-buffer before capture.

- [ ] **Step 4: Verify**

```bash
cd firmware
pio test -e native -f test_mute_state
pio run -e xiao_esp32s3
```

- [ ] **Step 5: Commit**

```bash
git add firmware/src firmware/test/test_mute_state
git commit -m "feat: persist wearable mute state"
```

### Task 4: Oldest-First Overflow

**Files:**
- Modify: `firmware/src/ring_buffer_layout.h`
- Modify: `firmware/src/psram_buffer.h`
- Modify: `firmware/src/ble_transport.h`
- Modify: `firmware/src/main.ino`
- Test: `firmware/test/test_ring_buffer_layout/test_main.cpp`
- Create: `firmware/test/test_overflow_policy/test_main.cpp`

**Interfaces:**
- Produces `PSRAMBuffer::dropOldest()` returning dropped `segmentId` or zero.
- Produces `BleTransport::cancelActiveForOverflow(uint32_t segmentId)`.
- Produces `uint32_t droppedSegmentCount()`.

- [ ] **Step 1: Write failing overflow tests**

Use a small pure layout fixture to reserve A/B/C, force D, and assert A is removed, D is stored, FIFO becomes B/C/D, and dropped count is one.

- [ ] **Step 2: Implement safe drop coordination**

Before dropping the front entry, compare its ID with the active transfer. If equal, reset transfer state and clear the active pointer. Drop under the PSRAM mutex, then store newest. Never call normal `dequeue()` for overflow.

- [ ] **Step 3: Emit status**

Set overflow flag and increment dropped count for every discarded Segment. Clear only the transient flag after a successful `DEVICE_STATUS` notify; never clear the cumulative count.

- [ ] **Step 4: Verify and commit**

```bash
cd firmware
pio test -e native
pio run -e xiao_esp32s3
git add firmware/src firmware/test
git commit -m "feat: preserve newest audio on buffer overflow"
```

### Task 5: Bonded Single-Peer GATT

**Files:**
- Modify: `firmware/src/ble_transport.h`
- Create: `firmware/src/bond_policy.h`
- Create: `firmware/test/test_bond_policy/test_main.cpp`

**Interfaces:**
- Audio characteristic requires encrypted access before notifications.
- Control characteristic requires encrypted access before writes/notifications.
- `BondPolicy` accepts the first bonded identity and rejects another identity.

- [ ] **Step 1: Write failing bond-policy tests**

Test no-bond accepts first identity, same identity reconnects, second identity is rejected, and forget clears the accepted identity.

- [ ] **Step 2: Configure NimBLE security**

Before server creation:

```cpp
NimBLEDevice::setSecurityAuth(true, false, true);
NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
```

Create characteristics with encrypted property flags supported by pinned NimBLE 2.3.2. Trigger security when an unencrypted peer subscribes/writes. On authentication complete, disconnect non-bonded or wrong-identity peers.

- [ ] **Step 3: Implement forget command**

Accept `FORGET_BOND` only on an encrypted bonded connection. Notify `FORGET_BOND_OK`, then delete bonds and restart advertising in pairing mode after the notification is queued.

- [ ] **Step 4: Embedded verification**

Build and test with iPhone: first access prompts pairing, reconnect does not prompt, another phone cannot subscribe, forget allows new pairing.

- [ ] **Step 5: Commit**

```bash
git add firmware/src firmware/test/test_bond_policy
git commit -m "feat: require one bonded wearable client"
```

### Task 6: Mobile Device Controller and Saved Identity

**Files:**
- Create: `mobile/lib/models/device_status.dart`
- Create: `mobile/lib/services/device_identity_store.dart`
- Create: `mobile/lib/services/device_controller.dart`
- Modify: `mobile/lib/services/ble_service.dart`
- Test: `mobile/test/services/device_controller_test.dart`

**Interfaces:**
- `DeviceConnectionState` enum from the spec.
- `DeviceController.stateStream`, `pair()`, `start()`, `setMuted(bool)`, `forget()`, `dispose()`.
- `DeviceIdentityStore.loadRemoteId/saveRemoteId/clear`.

- [ ] **Step 1: Write controller tests with fake BLE/store**

Cover first pairing save, launch auto-connect, reconnect delays 0/2/5/10/30, Bluetooth off, reconnect cancellation, restored status parsing, mute command acknowledgement, and forget clearing identity.

- [ ] **Step 2: Extract BLE port**

Define an injected interface around scan/connect/discover/subscribe/write so tests do not call platform channels. Preserve current packet assembler/relay behavior.

- [ ] **Step 3: Implement saved auto-connect**

Use `BluetoothDevice.fromId(remoteId)` and `connect(autoConnect: true, mtu: null)`. On every connected event rediscover services and resubscribe before READY. First pairing scans with Echo service UUID and saves the resulting ID.

- [ ] **Step 4: Verify and commit**

```bash
cd mobile
flutter test test/services/device_controller_test.dart
flutter analyze
git add mobile/lib/models mobile/lib/services mobile/test/services
git commit -m "feat: remember and reconnect Echo wearable"
```

### Task 7: iOS Background, Network Policy, and Notifications

**Files:**
- Modify: `mobile/ios/Runner/Info.plist`
- Modify: `mobile/ios/Runner/AppDelegate.swift`
- Modify: `mobile/android/app/src/main/AndroidManifest.xml`
- Modify: `mobile/lib/main.dart`
- Create: `mobile/lib/services/network_policy.dart`
- Create: `mobile/lib/services/notification_service.dart`
- Create: `mobile/lib/services/app_lifecycle_coordinator.dart`
- Test: `mobile/test/services/network_policy_test.dart`
- Test: `mobile/test/services/notification_service_test.dart`

**Interfaces:**
- `NetworkPolicy.canUpload(Set<NetworkType>)` with cellular default and Wi-Fi-only option.
- `NotificationService.scheduleDisconnected/cancelDisconnected/showLoss/showUploadFailure`.
- Lifecycle coordinator initializes restore state before any BLE work.

- [ ] **Step 1: Add background capability**

Add:

```xml
<key>UIBackgroundModes</key>
<array><string>bluetooth-central</string></array>
```

Call `FlutterBluePlus.setOptions(restoreState: true)` before constructing `BleService` or querying adapter state.

- [ ] **Step 2: Write and implement network-policy tests**

Assert default accepts Wi-Fi/mobile, Wi-Fi-only rejects mobile/none, and all requests still handle timeout/error because connectivity does not guarantee Internet.

- [ ] **Step 3: Gate BLE upload**

Before HTTP upload, evaluate current network policy. A blocked upload returns a retryable result and never sends UPLOAD_OK. Re-check connectivity on every retry and app resume.

- [ ] **Step 4: Write and implement notification tests**

Use an injected notifications port. Disconnect schedules ID 100 after two minutes; reconnect cancels 100; dropped audio uses ID 101; repeated backend failure uses ID 102. Normal transcript completion produces no notification.

- [ ] **Step 5: Configure platform permissions**

Request notification permission during onboarding, not startup. Scope Android legacy Bluetooth/location permissions by SDK and add `neverForLocation` to scan permission. Do not request exact-alarm permission; two-minute disconnect warnings use inexact scheduling acceptable for beta.

- [ ] **Step 6: Verify release behavior**

```bash
cd mobile
flutter test test/services
flutter analyze
flutter build ios --release --no-codesign
flutter build apk --debug
```

Install the iOS release build, lock the phone, and relay at least five Segments. Force-close behavior is explicitly excluded.

- [ ] **Step 7: Commit**

```bash
git add mobile
git commit -m "feat: support iOS background wearable relay"
```

### Task 8: Device Reliability Acceptance Gate

**Files:**
- Modify only when a focused test exposes a defect.

- [ ] Run all firmware native tests and XIAO build.
- [ ] Run all Flutter tests/analyze and iOS release/Android debug builds.
- [ ] Verify pairing, encrypted access, background/locked relay, reconnect, Bluetooth toggle, backend outage, mute reboot persistence, overflow loss count, Wi-Fi-only behavior, and local notifications.
- [ ] Inspect BLE logs to verify iOS negotiates MTU without an explicit request and Android requests the configured MTU after connection.
- [ ] Run the continuous two-hour foreground/background/locked-screen matrix; exclude user force-quit and record any iOS-managed restoration event.
- [ ] Capture serial/app logs proving normal dequeue only follows UPLOAD_OK and overflow drops are explicitly counted.
- [ ] Do not begin the memory-controls plan until this gate passes or all hardware-only failures are documented with owners.
