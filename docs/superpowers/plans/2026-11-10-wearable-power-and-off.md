# Wearable power, standby and turning Echo off — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A cooler, longer-lasting Echo. The CPU runs at 80 MHz. Mute stops the microphone's I2S driver. Echo can be turned off from the app or by holding its button for 5 s: it first makes its speech safe, then deep-sleeps. Holding the button for 1.5 s wakes it.

**Architecture:** The decisions live in pure headers with native Unity tests: `PowerOffPolicy`, `WakeGate`, `ButtonGesture` and `TieredQueue::spillOldestToCard`. `main.ino` performs their effects: it stops and starts the microphone, finalizes the segment being recorded, spills to the card and puts the chip to sleep. Two new control frames (`POWER_OFF 0x1C`, `POWER_STATE 0x24`) keep protocol 6; the app gates them on firmware 0.10.0. The app adds `turningOff` and `off` to `DeviceConnectionState` and a "Turn off Echo" row.

**Tech Stack:** ESP32-S3 Arduino (PlatformIO, NimBLE, ESP-IDF sleep APIs), Unity native tests (C++11), Flutter/Dart with flutter_test.

**Spec:** [docs/superpowers/specs/2026-11-10-wearable-power-and-off-design.md](../specs/2026-11-10-wearable-power-and-off-design.md)

---

## Global constraints

- **Toolchain.** This Windows machine has neither PlatformIO nor Flutter nor a C++ compiler on `PATH`; CI (`.github/workflows/ci.yml`) runs `pio run -e xiao_esp32s3`, `pio test -e native`, `flutter analyze` and `flutter test`.
  - Before Task 1, install PlatformIO: `python -m pip install platformio`.
  - The `native` env needs a host compiler: either MinGW-w64 `g++` on `PATH`, or WSL with `pip install platformio` inside it.
  - Flutter: use an existing SDK if the user has one; otherwise ask the user.
  - If a toolchain cannot be installed, say so in the task report, write the tests anyway and let CI run them. Never claim a test passed without seeing it pass.
- **Never** trigger iOS builds (`ios-unsigned.yml`, `flutter build ios`, Xcode). Never push, deploy, or run `make firmware-release`; the user signs releases.
- **The worktree has unrelated uncommitted work** (backend STT recovery, `docs/PROJECT-STATUS.md`, `docs/schema.sql`, a README hunk at line 505, migration 039, `docs/*.stl`). Stage only the files each task names, with explicit paths (`git add <path>`), never `git add -A` or `git add .`.
- Every commit message ends with a blank line and `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.
- **Protocol stays 6.** Do not change `PROTOCOL_VERSION` or `DeviceProtocol.supportedVersions`.
- **Style.**
  - Firmware: C++11, header-only pure classes, short doc comments in the codebase's voice: what it is for, not how.
  - Dart: `final class`, exhaustive `switch` expressions, no comments that restate code.
- **Commands:**
  - Firmware tests: `cd firmware; pio test -e native` (one suite: `pio test -e native -f test_power_off_policy`).
  - Firmware build: `cd firmware; pio run -e xiao_esp32s3`.
  - App tests: `cd mobile; flutter test <file>`. App lint: `cd mobile; flutter analyze --no-fatal-infos --no-fatal-warnings`.

## File map

| File | Change |
|------|--------|
| `firmware/src/ble_protocol.h` | `FRAME_POWER_OFF`, `FRAME_POWER_STATE`, the states, `ControlFrame::turnOff`, decode, `encodePowerState` |
| `firmware/src/button_gesture.h` | `VERY_LONG_PRESS`; `LONG_PRESS` moves to release |
| `firmware/src/tiered_queue.h` | `Spill`, `spillOldestToCard()`, `memoryCount()` |
| `firmware/src/power_off_policy.h` | new, pure |
| `firmware/src/wake_gate.h` | new, pure |
| `firmware/src/audio_capture.h` | `isRunning()` |
| `firmware/src/ble_transport.h` | power-off callback, `setPowerState`, POWER_STATE notify, resend on READY, `shutdown()` |
| `firmware/src/config.h` | 0.10.0, `BUTTON_POWER_OFF_MS`, `BUTTON_WAKE_HOLD_MS`, `CPU_FREQ_MHZ` |
| `firmware/src/main.ino` | wake gate, CPU frequency, microphone sync, power-off sequence, deep sleep, button, frame timing |
| `firmware/test/test_ble_protocol/test_main.cpp` | power frames |
| `firmware/test/test_button_gesture/test_main.cpp` | rewritten for release and very-long press |
| `firmware/test/test_tiered_queue/test_main.cpp` | spill tests |
| `firmware/test/test_power_off_policy/test_main.cpp` | new |
| `firmware/test/test_wake_gate/test_main.cpp` | new |
| `mobile/lib/services/device/device_protocol.dart` | `DevicePowerState`, `powerOff()`, `cancelPowerOff()`, `parsePowerState()`, `powerOffFirmware` |
| `mobile/lib/services/device/device_ble_port.dart` | `powerStateStream`, `powerOff()`, `cancelPowerOff()` |
| `mobile/lib/services/device/ble_service.dart` | implements them |
| `mobile/lib/models/device_status.dart` | `turningOff`, `off` |
| `mobile/lib/services/device/device_controller.dart` | `turnOff()`, `cancelTurnOff()`, power state |
| `mobile/lib/widgets/device_pill.dart`, `device_instrument.dart` | labels, "Keep Echo on" |
| `mobile/lib/screens/profile_screen.dart` | `stateLabel` |
| `mobile/lib/services/device/live_activity_service.dart` | `off` ends it, `turningOff` shows muted |
| `mobile/lib/services/app/app_lifecycle_coordinator.dart` | no disconnect notice for `off`/`turningOff` |
| `mobile/lib/screens/echo_device_screen.dart` | "Turn off Echo" row and dialog, Keep Echo on |
| Test fakes: `device_controller_test.dart`, `echo_device_screen_test.dart`, `profile_screen_test.dart` | new port members |
| `README.md`, `docs/ROADMAP.md`, `docs/superpowers/specs/...` | button gestures, status, hardware checklist |

---

### Task 1: Power frames in the protocol

**Files:**
- Modify: `firmware/src/ble_protocol.h`
- Test: `firmware/test/test_ble_protocol/test_main.cpp`

- [ ] **Step 1: Write the failing tests.** In `test_main.cpp`, after `test_mic_gain_frame_takes_1_to_8()`, add:

```cpp
void test_power_off_frame_turns_off_or_cancels() {
    const uint8_t off[] = {FRAME_POWER_OFF, 1};
    const uint8_t cancel[] = {FRAME_POWER_OFF, 0};
    const uint8_t invalid[] = {FRAME_POWER_OFF, 2};
    const uint8_t shortFrame[] = {FRAME_POWER_OFF};
    const uint8_t longFrame[] = {FRAME_POWER_OFF, 1, 0};
    ControlFrame decoded = {};

    TEST_ASSERT_EQUAL_HEX8(0x1C, FRAME_POWER_OFF);
    TEST_ASSERT_TRUE(decodeControlFrame(off, sizeof(off), decoded));
    TEST_ASSERT_EQUAL_UINT8(FRAME_POWER_OFF, decoded.type);
    TEST_ASSERT_TRUE(decoded.turnOff);
    TEST_ASSERT_TRUE(decodeControlFrame(cancel, sizeof(cancel), decoded));
    TEST_ASSERT_FALSE(decoded.turnOff);
    TEST_ASSERT_FALSE(decodeControlFrame(invalid, sizeof(invalid), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(shortFrame, sizeof(shortFrame), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(longFrame, sizeof(longFrame), decoded));
}

void test_power_state_exact_bytes_and_protocol_unchanged() {
    uint8_t frame[POWER_STATE_SIZE] = {};
    TEST_ASSERT_EQUAL_UINT32(POWER_STATE_SIZE,
        encodePowerState(POWER_STATE_REFUSED, POWER_REASON_UPDATING, frame, sizeof(frame)));
    const uint8_t refused[] = {0x24, 3, 1};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(refused, frame, sizeof(refused));

    TEST_ASSERT_EQUAL_UINT32(POWER_STATE_SIZE,
        encodePowerState(POWER_STATE_ON, POWER_REASON_NONE, frame, sizeof(frame)));
    const uint8_t on[] = {0x24, 0, 0};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(on, frame, sizeof(on));

    TEST_ASSERT_EQUAL_UINT32(0, encodePowerState(POWER_STATE_REFUSED + 1, 0, frame, sizeof(frame)));
    TEST_ASSERT_EQUAL_UINT32(0, encodePowerState(POWER_STATE_OFF, 0, frame, POWER_STATE_SIZE - 1));
    TEST_ASSERT_EQUAL_UINT32(0, encodePowerState(POWER_STATE_OFF, 0, nullptr, POWER_STATE_SIZE));
    // New frames are gated on the firmware version, as SET_MIC_GAIN: no protocol bump
    TEST_ASSERT_EQUAL_UINT8(6, PROTOCOL_VERSION);
}
```

and in `main()`, after `RUN_TEST(test_mic_gain_frame_takes_1_to_8);`:

```cpp
    RUN_TEST(test_power_off_frame_turns_off_or_cancels);
    RUN_TEST(test_power_state_exact_bytes_and_protocol_unchanged);
```

- [ ] **Step 2: Run the tests and confirm they fail.** `cd firmware; pio test -e native -f test_ble_protocol`. Expected: a compile error, `FRAME_POWER_OFF` not declared.

- [ ] **Step 3: Implement in `ble_protocol.h`.** After `constexpr uint8_t MAX_MIC_GAIN = 8;` add:

```cpp
// app -> wearable, firmware 0.10.0 on: [type, 1 = turn off | 0 = cancel]. No protocol bump,
// as SET_MIC_GAIN: the app sends it only to a firmware that knows it
constexpr uint8_t FRAME_POWER_OFF = 0x1C;
```

After `constexpr uint8_t FRAME_OTA_STATUS = 0x23;` add:

```cpp
// wearable -> app, firmware 0.10.0 on: [type, state, reason]. Older apps ignore it
constexpr uint8_t FRAME_POWER_STATE = 0x24;
```

After the `OTA_ERROR_*` constants add:

```cpp
constexpr uint8_t POWER_STATE_ON = 0;           // a turn-off was cancelled
constexpr uint8_t POWER_STATE_TURNING_OFF = 1;  // making its speech safe, then off
constexpr uint8_t POWER_STATE_OFF = 2;          // about to sleep; its button wakes it
constexpr uint8_t POWER_STATE_REFUSED = 3;      // stays on: see the reason
constexpr uint8_t POWER_REASON_NONE = 0;
constexpr uint8_t POWER_REASON_UPDATING = 1;    // a firmware update, or one not yet confirmed
```

Among the sizes, after `SET_MIC_GAIN_SIZE`:

```cpp
constexpr size_t POWER_OFF_SIZE = 2;
constexpr size_t POWER_STATE_SIZE = 3;
```

In `struct ControlFrame`, after `uint8_t micGain;`:

```cpp
    bool turnOff;
```

After `encodePhotoFailed`:

```cpp
inline size_t encodePowerState(uint8_t state, uint8_t reason, uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < POWER_STATE_SIZE || state > POWER_STATE_REFUSED) return 0;
    output[0] = FRAME_POWER_STATE;
    output[1] = state;
    output[2] = reason;
    return POWER_STATE_SIZE;
}
```

In `decodeControlFrame`, after the `FRAME_SET_MIC_GAIN` case:

```cpp
        case FRAME_POWER_OFF:
            if (length != POWER_OFF_SIZE || input[1] > 1) return false;
            frame.turnOff = input[1] == 1;
            return true;
```

- [ ] **Step 4: Run the tests and confirm they pass.** `pio test -e native -f test_ble_protocol`. Expected: all tests PASS.

- [ ] **Step 5: Commit.**

```powershell
git add firmware/src/ble_protocol.h firmware/test/test_ble_protocol/test_main.cpp
git commit -m "firmware: POWER_OFF and POWER_STATE frames, protocol stays 6" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: The button: mute on release, power-off at 5 s

**Files:**
- Modify: `firmware/src/button_gesture.h`
- Test: `firmware/test/test_button_gesture/test_main.cpp` (rewritten)

- [ ] **Step 1: Write the failing tests.** Replace the whole of `test_main.cpp` with:

```cpp
#include <unity.h>

#include "button_gesture.h"

using Event = ButtonGesture::Event;

void test_a_short_press_fires_on_release() {
    ButtonGesture button(50, 1500, 5000);
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 0));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 60));   // debounced: pressed
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 400));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 420));
    TEST_ASSERT_EQUAL(Event::SHORT_PRESS, button.update(false, 480));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 600));
}

void test_a_long_press_fires_on_release_not_while_held() {
    ButtonGesture button(50, 1500, 5000);
    button.update(true, 0);
    button.update(true, 60);
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 1500));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 3000));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 3010));  // still debouncing
    TEST_ASSERT_EQUAL(Event::LONG_PRESS, button.update(false, 3060));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 3200));
}

void test_a_very_long_press_fires_while_held_and_nothing_on_release() {
    ButtonGesture button(50, 1500, 5000);
    button.update(true, 0);
    button.update(true, 60);
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 4999));
    TEST_ASSERT_EQUAL(Event::VERY_LONG_PRESS, button.update(true, 5000));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 7000));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 7010));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 7100));  // no long press too
}

void test_bounces_are_ignored() {
    ButtonGesture button(50, 1500, 5000);
    button.update(true, 0);
    button.update(false, 10);
    button.update(true, 20);
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 30));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 200));  // never stably pressed
}

void test_presses_follow_one_another() {
    ButtonGesture button(50, 1500, 5000);
    button.update(true, 0);
    button.update(true, 60);
    button.update(false, 100);
    TEST_ASSERT_EQUAL(Event::SHORT_PRESS, button.update(false, 160));
    button.update(true, 300);
    button.update(true, 360);
    button.update(false, 2000);
    TEST_ASSERT_EQUAL(Event::LONG_PRESS, button.update(false, 2050));
    button.update(true, 2200);
    button.update(true, 2260);
    TEST_ASSERT_EQUAL(Event::VERY_LONG_PRESS, button.update(true, 7200));
}

void test_millis_wraparound() {
    const uint32_t start = 0xFFFFFF00U;
    ButtonGesture longPress(50, 1500, 5000);
    longPress.update(true, start);
    longPress.update(true, start + 60);
    longPress.update(false, start + 1600);
    TEST_ASSERT_EQUAL(Event::LONG_PRESS, longPress.update(false, start + 1660));

    ButtonGesture veryLong(50, 1500, 5000);
    veryLong.update(true, start);
    veryLong.update(true, start + 60);
    TEST_ASSERT_EQUAL(Event::VERY_LONG_PRESS, veryLong.update(true, start + 5000));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_a_short_press_fires_on_release);
    RUN_TEST(test_a_long_press_fires_on_release_not_while_held);
    RUN_TEST(test_a_very_long_press_fires_while_held_and_nothing_on_release);
    RUN_TEST(test_bounces_are_ignored);
    RUN_TEST(test_presses_follow_one_another);
    RUN_TEST(test_millis_wraparound);
    return UNITY_END();
}
```

- [ ] **Step 2: Run the tests and confirm they fail.** `pio test -e native -f test_button_gesture`. Expected: a compile error, because there is no 3-argument constructor and no `VERY_LONG_PRESS`.

- [ ] **Step 3: Implement.** Replace the class in `button_gesture.h` (keep `#pragma once` and `#include <cstdint>`):

```cpp
/**
 * The wearable's button, read by polling: a short, a long or a very long press.
 *
 * The level is debounced first. Released before `longPressMs`: a short press (a photo).
 * Released between `longPressMs` and `veryLongPressMs`: a long press (mute), on release, so
 * holding on towards the very long press never mutes first. Held for `veryLongPressMs`: a
 * very long press (turn off), as soon as it is reached; releasing it then does nothing more.
 */
class ButtonGesture {
public:
    enum Event : uint8_t { NONE, SHORT_PRESS, LONG_PRESS, VERY_LONG_PRESS };

    ButtonGesture(uint32_t debounceMs, uint32_t longPressMs, uint32_t veryLongPressMs)
        : _debounceMs(debounceMs), _longPressMs(longPressMs), _veryLongPressMs(veryLongPressMs) {}

    /** `pressed`: the raw level now (true = held down). */
    Event update(bool pressed, uint32_t nowMs) {
        if (pressed != _raw) {
            _raw = pressed;
            _rawChangedAtMs = nowMs;
        }
        if (_raw != _stable && static_cast<uint32_t>(nowMs - _rawChangedAtMs) >= _debounceMs) {
            _stable = _raw;
            if (_stable) {
                _pressedAtMs = _rawChangedAtMs;
                _veryLongFired = false;
            } else if (!_veryLongFired) {
                const uint32_t heldMs = static_cast<uint32_t>(_rawChangedAtMs - _pressedAtMs);
                return heldMs >= _longPressMs ? LONG_PRESS : SHORT_PRESS;
            }
        }
        if (_stable && !_veryLongFired &&
            static_cast<uint32_t>(nowMs - _pressedAtMs) >= _veryLongPressMs) {
            _veryLongFired = true;
            return VERY_LONG_PRESS;
        }
        return NONE;
    }

private:
    uint32_t _debounceMs;
    uint32_t _longPressMs;
    uint32_t _veryLongPressMs;
    bool _raw = false;
    bool _stable = false;
    bool _veryLongFired = false;
    uint32_t _rawChangedAtMs = 0;
    uint32_t _pressedAtMs = 0;
};
```

`main.ino` still constructs it with two arguments, which breaks the device build until Task 7. That is expected; the native tests do not build `main.ino`.

- [ ] **Step 4: Run the tests and confirm they pass.** `pio test -e native -f test_button_gesture`. Expected: 6 tests PASS.

- [ ] **Step 5: Commit.**

```powershell
git add firmware/src/button_gesture.h firmware/test/test_button_gesture/test_main.cpp
git commit -m "firmware: long press on release, very long press for turning off" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Moving PSRAM's speech to the card, one segment at a time

One segment per call, not all at once: the loop keeps serving BLE between moves. Encrypting and writing 4 MB in one go would stall the link for seconds.

**Files:**
- Modify: `firmware/src/tiered_queue.h`
- Test: `firmware/test/test_tiered_queue/test_main.cpp`

- [ ] **Step 1: Write the failing tests.** Before `int main`, add:

```cpp
void test_spilling_moves_psram_to_the_card_oldest_first() {
    FakeHot hot(300);
    MemoryStorage card;
    SegmentLog log(card, 4096);
    TEST_ASSERT_TRUE(log.begin());
    TieredQueue<FakeHot> queue(hot);
    moved.clear();
    queue.attachCard(&log, staging, sizeof(staging), [](uint32_t id) { moved.push_back(id); });
    for (uint32_t id = 1; id <= 3; ++id) TEST_ASSERT_TRUE(storeSegment(queue, id));
    TEST_ASSERT_EQUAL_UINT16(3, queue.memoryCount());

    TEST_ASSERT_TRUE(queue.spillOldestToCard() == TieredQueue<FakeHot>::Spill::MOVED);
    TEST_ASSERT_TRUE(queue.spillOldestToCard() == TieredQueue<FakeHot>::Spill::MOVED);
    TEST_ASSERT_TRUE(queue.spillOldestToCard() == TieredQueue<FakeHot>::Spill::MOVED);
    TEST_ASSERT_TRUE(queue.spillOldestToCard() == TieredQueue<FakeHot>::Spill::EMPTY);

    TEST_ASSERT_EQUAL_UINT16(0, queue.memoryCount());
    TEST_ASSERT_EQUAL_UINT32(3, moved.size());  // each announced before moving
    std::vector<uint32_t> order = drain(queue);
    std::vector<uint32_t> expected = {1, 2, 3};
    TEST_ASSERT_EQUAL_UINT32(expected.size(), order.size());
    for (size_t i = 0; i < expected.size(); ++i) TEST_ASSERT_EQUAL_UINT32(expected[i], order[i]);
}

void test_without_a_card_spilling_is_refused_unless_empty() {
    FakeHot hot(300);
    TieredQueue<FakeHot> queue(hot);
    TEST_ASSERT_TRUE(queue.spillOldestToCard() == TieredQueue<FakeHot>::Spill::EMPTY);
    TEST_ASSERT_TRUE(storeSegment(queue, 1));
    TEST_ASSERT_TRUE(queue.spillOldestToCard() == TieredQueue<FakeHot>::Spill::REFUSED);
    TEST_ASSERT_EQUAL_UINT16(1, queue.memoryCount());
}

void test_a_failing_card_refuses_and_psram_keeps_the_segment() {
    FakeHot hot(300);
    MemoryStorage card;
    SegmentLog log(card, 4096);
    TEST_ASSERT_TRUE(log.begin());
    TieredQueue<FakeHot> queue(hot);
    queue.attachCard(&log, staging, sizeof(staging), nullptr);
    TEST_ASSERT_TRUE(storeSegment(queue, 1));
    card.failWrites = true;
    TEST_ASSERT_TRUE(queue.spillOldestToCard() == TieredQueue<FakeHot>::Spill::REFUSED);
    TEST_ASSERT_EQUAL_UINT16(1, queue.memoryCount());
    TEST_ASSERT_EQUAL_UINT32(0, queue.droppedSegmentCount());
}
```

and in `main()`:

```cpp
    RUN_TEST(test_spilling_moves_psram_to_the_card_oldest_first);
    RUN_TEST(test_without_a_card_spilling_is_refused_unless_empty);
    RUN_TEST(test_a_failing_card_refuses_and_psram_keeps_the_segment);
```

- [ ] **Step 2: Run the tests and confirm they fail.** `pio test -e native -f test_tiered_queue`. Expected: a compile error, `spillOldestToCard` and `memoryCount` not declared.

- [ ] **Step 3: Implement in `tiered_queue.h`.** In the public section, after `store(...)`:

```cpp
    enum class Spill : uint8_t { MOVED, EMPTY, REFUSED };

    /** Turning off: PSRAM's oldest segment to the card, which keeps it through deep sleep.
     *  EMPTY once PSRAM holds nothing; REFUSED without a card, or when it is full or
     *  failing (the segment stays in PSRAM, for the phone). */
    Spill spillOldestToCard() {
        BufferedSegment oldest = {};
        const uint8_t* oldestData = nullptr;
        if (!_hot.peek(oldest, &oldestData)) return Spill::EMPTY;
        if (_card == nullptr) return Spill::REFUSED;
        if (_onMove != nullptr) _onMove(oldest.segmentId);
        if (!_card->append(oldest, oldestData)) return Spill::REFUSED;
        _hot.dequeue();
        return Spill::MOVED;
    }

    /** Segments only in PSRAM: lost if Echo sleeps now. */
    uint16_t memoryCount() const { return _hot.count(); }
```

- [ ] **Step 4: Run the tests and confirm they pass.** `pio test -e native -f test_tiered_queue`. Expected: all tests PASS.

- [ ] **Step 5: Commit.**

```powershell
git add firmware/src/tiered_queue.h firmware/test/test_tiered_queue/test_main.cpp
git commit -m "firmware: move PSRAM's speech to the card one segment at a time" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: `PowerOffPolicy`, deciding when Echo may sleep

**Files:**
- Create: `firmware/src/power_off_policy.h`
- Test: `firmware/test/test_power_off_policy/test_main.cpp`

- [ ] **Step 1: Write the failing tests.** Create `firmware/test/test_power_off_policy/test_main.cpp`:

```cpp
#include <unity.h>

#include "power_off_policy.h"

using State = PowerOffPolicy::State;
using Request = PowerOffPolicy::Request;

void test_a_request_starts_turning_off_once() {
    PowerOffPolicy policy;
    TEST_ASSERT_TRUE(policy.state() == State::ON);
    TEST_ASSERT_TRUE(policy.request(false) == Request::ACCEPTED);
    TEST_ASSERT_TRUE(policy.state() == State::TURNING_OFF);
    TEST_ASSERT_TRUE(policy.request(false) == Request::ALREADY_TURNING_OFF);
}

void test_refused_while_updating() {
    PowerOffPolicy policy;
    TEST_ASSERT_TRUE(policy.request(true) == Request::REFUSED_UPDATING);
    TEST_ASSERT_TRUE(policy.state() == State::ON);
}

void test_it_spills_to_the_card_then_sleeps_once_psram_is_empty() {
    PowerOffPolicy policy;
    policy.request(false);
    TEST_ASSERT_TRUE(policy.shouldSpill(true));
    TEST_ASSERT_TRUE(policy.update(2) == State::TURNING_OFF);
    TEST_ASSERT_TRUE(policy.update(0) == State::OFF_NOW);
}

void test_a_refusing_card_waits_for_the_phone() {
    PowerOffPolicy policy;
    policy.request(false);
    policy.onCardRefused();
    TEST_ASSERT_FALSE(policy.shouldSpill(true));
    for (int i = 0; i < 1000; ++i) TEST_ASSERT_TRUE(policy.update(3) == State::TURNING_OFF);
    TEST_ASSERT_TRUE(policy.update(0) == State::OFF_NOW);
}

void test_without_a_card_it_never_spills() {
    PowerOffPolicy policy;
    policy.request(false);
    TEST_ASSERT_FALSE(policy.shouldSpill(false));
}

void test_cancel_turns_it_back_on_and_a_new_request_tries_the_card_again() {
    PowerOffPolicy policy;
    TEST_ASSERT_FALSE(policy.cancel());
    policy.request(false);
    policy.onCardRefused();
    TEST_ASSERT_TRUE(policy.cancel());
    TEST_ASSERT_TRUE(policy.state() == State::ON);
    TEST_ASSERT_TRUE(policy.request(false) == Request::ACCEPTED);
    TEST_ASSERT_TRUE(policy.shouldSpill(true));
}

void test_while_on_an_empty_psram_does_not_turn_it_off() {
    PowerOffPolicy policy;
    TEST_ASSERT_TRUE(policy.update(0) == State::ON);
    TEST_ASSERT_FALSE(policy.shouldSpill(true));
}

void test_once_off_now_it_cannot_be_cancelled() {
    PowerOffPolicy policy;
    policy.request(false);
    policy.update(0);
    TEST_ASSERT_FALSE(policy.cancel());
    TEST_ASSERT_TRUE(policy.state() == State::OFF_NOW);
    TEST_ASSERT_TRUE(policy.request(false) == Request::ALREADY_TURNING_OFF);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_a_request_starts_turning_off_once);
    RUN_TEST(test_refused_while_updating);
    RUN_TEST(test_it_spills_to_the_card_then_sleeps_once_psram_is_empty);
    RUN_TEST(test_a_refusing_card_waits_for_the_phone);
    RUN_TEST(test_without_a_card_it_never_spills);
    RUN_TEST(test_cancel_turns_it_back_on_and_a_new_request_tries_the_card_again);
    RUN_TEST(test_while_on_an_empty_psram_does_not_turn_it_off);
    RUN_TEST(test_once_off_now_it_cannot_be_cancelled);
    return UNITY_END();
}
```

- [ ] **Step 2: Run the tests and confirm they fail.** `pio test -e native -f test_power_off_policy`. Expected: a compile error, `power_off_policy.h` not found.

- [ ] **Step 3: Implement.** Create `firmware/src/power_off_policy.h`:

```cpp
#pragma once

#include <cstdint>

/**
 * Turning Echo off without losing what it heard.
 *
 * PSRAM is lost in deep sleep; the card and the phone are not. Once asked, Echo stops
 * listening and moves PSRAM's segments to the card, or, without a card that takes them,
 * waits for the phone to collect them. Only an empty PSRAM lets it sleep. Until then the
 * turn-off can be cancelled. A firmware update refuses it: its restart needs Echo on.
 */
class PowerOffPolicy {
public:
    enum class State : uint8_t { ON, TURNING_OFF, OFF_NOW };
    enum class Request : uint8_t { ACCEPTED, REFUSED_UPDATING, ALREADY_TURNING_OFF };

    Request request(bool updating) {
        if (_state != State::ON) return Request::ALREADY_TURNING_OFF;
        if (updating) return Request::REFUSED_UPDATING;
        _state = State::TURNING_OFF;
        _cardRefused = false;
        return Request::ACCEPTED;
    }

    /** True when it turned back on. Too late once it is about to sleep. */
    bool cancel() {
        if (_state != State::TURNING_OFF) return false;
        _state = State::ON;
        return true;
    }

    bool shouldSpill(bool cardInUse) const {
        return _state == State::TURNING_OFF && cardInUse && !_cardRefused;
    }

    /** The card is full or failing: the rest waits for the phone. */
    void onCardRefused() { _cardRefused = true; }

    State update(uint16_t segmentsInMemory) {
        if (_state == State::TURNING_OFF && segmentsInMemory == 0) _state = State::OFF_NOW;
        return _state;
    }

    State state() const { return _state; }

private:
    State _state = State::ON;
    bool _cardRefused = false;
};
```

- [ ] **Step 4: Run the tests and confirm they pass.** `pio test -e native -f test_power_off_policy`. Expected: 8 tests PASS.

- [ ] **Step 5: Commit.**

```powershell
git add firmware/src/power_off_policy.h firmware/test/test_power_off_policy/test_main.cpp
git commit -m "firmware: PowerOffPolicy, sleeping only once PSRAM is safe" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: `WakeGate`, waking only on a deliberate hold

**Files:**
- Create: `firmware/src/wake_gate.h`
- Test: `firmware/test/test_wake_gate/test_main.cpp`

- [ ] **Step 1: Write the failing tests.** Create `firmware/test/test_wake_gate/test_main.cpp`:

```cpp
#include <unity.h>

#include "wake_gate.h"

using Decision = WakeGate::Decision;

void test_a_hold_long_enough_boots() {
    WakeGate gate(1500, 50);
    TEST_ASSERT_TRUE(gate.update(true, 0) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(true, 1499) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(true, 1500) == Decision::BOOT);
}

void test_released_early_it_sleeps_again_after_the_debounce() {
    WakeGate gate(1500, 50);
    gate.update(true, 0);
    TEST_ASSERT_TRUE(gate.update(false, 400) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(false, 449) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(false, 450) == Decision::SLEEP);
}

void test_a_bounce_does_not_send_it_back_to_sleep() {
    WakeGate gate(1500, 50);
    gate.update(true, 0);
    gate.update(false, 100);
    TEST_ASSERT_TRUE(gate.update(true, 120) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(false, 130) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(true, 140) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(true, 1500) == Decision::BOOT);
}

void test_a_glitch_with_the_button_up_sleeps_again() {
    WakeGate gate(1500, 50);
    TEST_ASSERT_TRUE(gate.update(false, 0) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(false, 50) == Decision::SLEEP);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_a_hold_long_enough_boots);
    RUN_TEST(test_released_early_it_sleeps_again_after_the_debounce);
    RUN_TEST(test_a_bounce_does_not_send_it_back_to_sleep);
    RUN_TEST(test_a_glitch_with_the_button_up_sleeps_again);
    return UNITY_END();
}
```

- [ ] **Step 2: Run the tests and confirm they fail.** `pio test -e native -f test_wake_gate`. Expected: a compile error, `wake_gate.h` not found.

- [ ] **Step 3: Implement.** Create `firmware/src/wake_gate.h`:

```cpp
#pragma once

#include <cstdint>

/**
 * Off, a press wakes the chip, but only a hold turns Echo on: a brush in a pocket
 * goes back to sleep. Times are from the wake, which the press itself caused.
 */
class WakeGate {
public:
    enum class Decision : uint8_t { WAIT, BOOT, SLEEP };

    WakeGate(uint32_t holdMs, uint32_t debounceMs) : _holdMs(holdMs), _debounceMs(debounceMs) {}

    Decision update(bool pressed, uint32_t sinceWakeMs) {
        if (pressed) {
            _released = false;
            return sinceWakeMs >= _holdMs ? Decision::BOOT : Decision::WAIT;
        }
        if (!_released) {
            _released = true;
            _releasedAtMs = sinceWakeMs;
        }
        return sinceWakeMs - _releasedAtMs >= _debounceMs ? Decision::SLEEP : Decision::WAIT;
    }

private:
    uint32_t _holdMs;
    uint32_t _debounceMs;
    bool _released = false;
    uint32_t _releasedAtMs = 0;
};
```

- [ ] **Step 4: Run the tests and confirm they pass.** `pio test -e native -f test_wake_gate`. Expected: 4 tests PASS.

- [ ] **Step 5: Commit.**

```powershell
git add firmware/src/wake_gate.h firmware/test/test_wake_gate/test_main.cpp
git commit -m "firmware: WakeGate, turning on only on a deliberate hold" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 6: The transport, carrying the power frames

`ble_transport.h` uses NimBLE and has no native test. Its decisions are in Tasks 1 and 4; this task is wiring only, checked by the device build in Task 7.

**Files:**
- Modify: `firmware/src/ble_transport.h`

- [ ] **Step 1: Add the callback and the state.** After `typedef void (*TakePhotoCallback)(void* context);`:

```cpp
    typedef void (*PowerOffCallback)(bool turnOff, void* context);
```

After `setTakePhotoCallback(...)`:

```cpp
    void setPowerOffCallback(PowerOffCallback callback, void* context) {
        _powerOffCallback = callback;
        _powerOffContext = context;
    }

    /** Tell the app (EchoBleProtocol::POWER_STATE_*). A refusal is an answer, not a state:
     *  it is not repeated on reconnect. */
    void setPowerState(uint8_t state, uint8_t reason = EchoBleProtocol::POWER_REASON_NONE) {
        if (state != EchoBleProtocol::POWER_STATE_REFUSED) _powerState = state;
        _pendingPowerState = state;
        _pendingPowerReason = reason;
        _powerStatePending = true;
    }

    bool powerStatePending() const { return _powerStatePending; }

    /** Just before deep sleep: the phone sees a clean disconnect, not a timeout. */
    void shutdown() {
        NimBLEDevice::getAdvertising()->stop();
        if (_connected && _server != nullptr && _connectionHandle != UINT16_MAX) {
            _server->disconnect(_connectionHandle);
        }
        _connected = false;
    }
```

- [ ] **Step 2: Notify it.** In `update()`, after the `_infoPending` block and before `// The update has the link to itself`:

```cpp
        if (_powerStatePending && _connected && _state.isReady()) {
            if (!notifyPowerState(deadlineUs)) return;
        }
```

After `notifyPhotoFailed(...)`:

```cpp
    bool notifyPowerState(uint32_t deadlineUs) {
        if (_controlCharacteristic == nullptr) return false;
        uint8_t frame[EchoBleProtocol::POWER_STATE_SIZE] = {};
        if (EchoBleProtocol::encodePowerState(_pendingPowerState, _pendingPowerReason,
                                              frame, sizeof(frame)) == 0) {
            _powerStatePending = false;
            return true;
        }
        if (!beforeBurstDeadline(deadlineUs)) return false;
        if (!_controlCharacteristic->notify(frame, sizeof(frame))) return false;
        Serial.printf("[BLE] power state=%u reason=%u\n", _pendingPowerState, _pendingPowerReason);
        _powerStatePending = false;
        return true;
    }
```

- [ ] **Step 3: Handle the frame, and resend after a reconnect.** In `handleControl`, after the `FRAME_SET_MIC_GAIN` case:

```cpp
            case EchoBleProtocol::FRAME_POWER_OFF:
                Serial.printf("[BLE] control FRAME_POWER_OFF turnOff=%d\n", frame.turnOff);
                if (_powerOffCallback != nullptr) _powerOffCallback(frame.turnOff, _powerOffContext);
                break;
```

In the `FRAME_READY` case, after `_infoPending = true;`:

```cpp
                // An app that reconnects while Echo turns off must not show it listening
                if (_powerState == EchoBleProtocol::POWER_STATE_TURNING_OFF) {
                    setPowerState(EchoBleProtocol::POWER_STATE_TURNING_OFF);
                }
```

- [ ] **Step 4: Members.** After `bool _infoPending = false;`:

```cpp
    PowerOffCallback _powerOffCallback = nullptr;
    void* _powerOffContext = nullptr;
    uint8_t _powerState = EchoBleProtocol::POWER_STATE_ON;
    uint8_t _pendingPowerState = EchoBleProtocol::POWER_STATE_ON;
    uint8_t _pendingPowerReason = EchoBleProtocol::POWER_REASON_NONE;
    bool _powerStatePending = false;
```

- [ ] **Step 5: Update the contract test.** `test_ble_transport_contract` counts the control notifications, and `notifyPowerState` adds one. In `test_transport_gates_each_notification_at_the_deadline`, change the expectation:

```cpp
    TEST_ASSERT_EQUAL_UINT32(6, countOccurrences(source, "_controlCharacteristic->notify("));
```

- [ ] **Step 6: Verify.** The device build is red until Task 7 (`ButtonGesture`'s constructor), so check for typos by reading: `git diff firmware/src/ble_transport.h`. Then confirm the native suites still pass: `pio test -e native`. `test_ble_transport_contract` must PASS with the new count.

- [ ] **Step 7: Commit.**

```powershell
git add firmware/src/ble_transport.h firmware/test/test_ble_transport_contract/test_main.cpp
git commit -m "firmware: transport carries POWER_OFF and POWER_STATE" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 7: The device: 80 MHz, a real standby, turning off and on

Hardware glue, checked by the device build and by the hardware checklist in Task 12. One change to the spec's wiring: the BLE callback only **records** the request. The loop acts on it after `bleTransport.update()`, because finalizing a segment from inside `handleControl` would re-enter the transport (`cancelActiveForOverflow`, `requestBufferStatus`) in the middle of its own update.

**Files:**
- Modify: `firmware/src/config.h`, `firmware/src/audio_capture.h`, `firmware/src/main.ino`
- Modify: `firmware/test/test_ble_transport_contract/test_main.cpp` (the mute block's anchor)

- [ ] **Step 1: `config.h`.** Set the version to 0.10.0:

```cpp
#define FIRMWARE_VERSION_MAJOR 0
#define FIRMWARE_VERSION_MINOR 10
#define FIRMWARE_VERSION_PATCH 0
```

Replace the button block (the comment and the three defines) with:

```cpp
// The button, between D1 (GPIO2) and GND (internal pull-up): a short press takes a photo,
// a long press (released after 1.5 s) mutes or resumes listening, a 5 s hold turns Echo
// off. Off, a 1.5 s hold turns it on (GPIO2 is an RTC pin: it can wake the chip)
#define BUTTON_PIN 2
#define BUTTON_DEBOUNCE_MS 50
#define BUTTON_LONG_PRESS_MS 1500
#define BUTTON_POWER_OFF_MS 5000
#define BUTTON_WAKE_HOLD_MS 1500

// 80 MHz is enough for Opus at 16 kHz mono and keeps BLE working; 240 MHz only ran hotter
#define CPU_FREQ_MHZ 80
```

- [ ] **Step 2: `audio_capture.h`.** In the public section, after `void end();`:

```cpp
    /** The I2S driver is installed: off while muted or turning off, to save power. */
    bool isRunning() const { return _initialized; }
```

- [ ] **Step 3: `main.ino`, includes and globals.**
  - After `#include <esp_ota_ops.h>`, add `#include <esp_sleep.h>` and `#include <driver/rtc_io.h>`.
  - After `#include "ota_health.h"`, add `#include "power_off_policy.h"` and `#include "wake_gate.h"`.
  - Replace `ButtonGesture button(BUTTON_DEBOUNCE_MS, BUTTON_LONG_PRESS_MS);` with:

```cpp
ButtonGesture button(BUTTON_DEBOUNCE_MS, BUTTON_LONG_PRESS_MS, BUTTON_POWER_OFF_MS);
PowerOffPolicy powerOff;
```

  - After `uint32_t segmentCrcAccumulator = ...;` add:

```cpp
// The microphone did not restart after a standby: Echo reports itself muted
bool micFailed = false;

// What the app asked over BLE: acted on by the loop, outside the transport's update
enum PowerRequest : uint8_t { POWER_REQUEST_NONE, POWER_REQUEST_OFF, POWER_REQUEST_CANCEL };
volatile PowerRequest powerRequest = POWER_REQUEST_NONE;

// How long a VAD frame takes to process: checks 80 MHz keeps up (32 ms of audio a frame)
uint32_t frameUsMax = 0;
uint64_t frameUsTotal = 0;
uint32_t frameCount = 0;
```

  - Next to the other forward declarations (`void discardInProgressCapture();`), add:

```cpp
void finalizeSegment();
void handlePowerOff(bool turnOff);
```

- [ ] **Step 4: `main.ino`, sleep and wake.** After `fatal(...)`, add:

```cpp
/** Deep sleep until the button is pressed. The LED pin is held high: the LED stays dark
 *  and, with a card, its chip select stays deselected. */
[[noreturn]] void sleepNow() {
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, HIGH);
    gpio_hold_en(static_cast<gpio_num_t>(LED_PIN));
    gpio_deep_sleep_hold_en();
    rtc_gpio_pullup_en(static_cast<gpio_num_t>(BUTTON_PIN));
    rtc_gpio_pulldown_dis(static_cast<gpio_num_t>(BUTTON_PIN));
    esp_sleep_enable_ext0_wakeup(static_cast<gpio_num_t>(BUTTON_PIN), 0);
    esp_deep_sleep_start();
}

/** Woken by the button: only a hold turns Echo on; the LED says so, then the button is
 *  released before anything reads it, or the hold would count as a press. */
void checkButtonWake() {
    if (esp_sleep_get_wakeup_cause() != ESP_SLEEP_WAKEUP_EXT0) return;
    gpio_deep_sleep_hold_dis();
    gpio_hold_dis(static_cast<gpio_num_t>(LED_PIN));
    rtc_gpio_deinit(static_cast<gpio_num_t>(BUTTON_PIN));
    pinMode(BUTTON_PIN, INPUT_PULLUP);
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, HIGH);

    WakeGate gate(BUTTON_WAKE_HOLD_MS, BUTTON_DEBOUNCE_MS);
    const uint32_t wokeAtMs = millis();
    while (true) {
        switch (gate.update(digitalRead(BUTTON_PIN) == LOW, millis() - wokeAtMs)) {
            case WakeGate::Decision::BOOT: {
                digitalWrite(LED_PIN, LOW);
                uint32_t releasedAtMs = millis();
                while (millis() - releasedAtMs < BUTTON_DEBOUNCE_MS) {
                    if (digitalRead(BUTTON_PIN) == LOW) releasedAtMs = millis();
                    delay(5);
                }
                digitalWrite(LED_PIN, HIGH);
                return;
            }
            case WakeGate::Decision::SLEEP:
                sleepNow();
            case WakeGate::Decision::WAIT:
                delay(10);
                break;
        }
    }
}
```

- [ ] **Step 5: `main.ino`, the microphone follows mute and power.** After `checkButtonWake()`:

```cpp
/** The I2S driver runs only while Echo listens: muted, failed or turning off, it is
 *  uninstalled, which is what makes standby cheap. */
void syncMicrophone() {
    const bool wanted = !muteState.isMuted() && !micFailed &&
                        powerOff.state() == PowerOffPolicy::State::ON;
    if (wanted == audio.isRunning()) return;
    if (!wanted) {
        audio.end();
        return;
    }
    if (audio.begin()) {
        vad.reset();
        return;
    }
    micFailed = true;
    indicators.setMuted(true);
    bleTransport.setMuted(true);
    Serial.println("[Audio] microphone did not restart: reported as muted");
}
```

In `handleTakePhoto`, after the `otaInProgress()` branch, add:

```cpp
    } else if (powerOff.state() != PowerOffPolicy::State::ON) {
        bleTransport.reportPhotoFailed(EchoBleProtocol::PHOTO_FAILED_BUSY);
```

In `handleMuteCommand`, add `micFailed = false;` as its first line, and `syncMicrophone();` after `bleTransport.setMuted(muteState.isMuted());`.

- [ ] **Step 6: `main.ino`, turning off.** After `handleMuteCommand`, add:

```cpp
void handlePowerOffCommand(bool turnOff, void*) {
    powerRequest = turnOff ? POWER_REQUEST_OFF : POWER_REQUEST_CANCEL;
}

void cancelPowerOff() {
    if (!powerOff.cancel()) return;
    indicators.setBlinking(false);
    syncMicrophone();
    bleTransport.setPowerState(EchoBleProtocol::POWER_STATE_ON);
    Serial.println("[Power] turn-off cancelled");
}

/** Stop listening, keep what was being said, then empty PSRAM before sleeping. */
void handlePowerOff(bool turnOff) {
    if (!turnOff) {
        cancelPowerOff();
        return;
    }
    switch (powerOff.request(bleTransport.otaInProgress() || otaHealth.onTrial())) {
        case PowerOffPolicy::Request::REFUSED_UPDATING:
            bleTransport.setPowerState(EchoBleProtocol::POWER_STATE_REFUSED,
                                       EchoBleProtocol::POWER_REASON_UPDATING);
            Serial.println("[Power] turn-off refused: updating");
            return;
        case PowerOffPolicy::Request::ALREADY_TURNING_OFF:
            bleTransport.setPowerState(EchoBleProtocol::POWER_STATE_TURNING_OFF);
            return;
        case PowerOffPolicy::Request::ACCEPTED:
            break;
    }
    if (state == STATE_RECORDING) finalizeSegment();
    else discardInProgressCapture();
    bleTransport.cancelPhoto();
    if (photoSlot.discard()) bleTransport.reportPhotoFailed(EchoBleProtocol::PHOTO_FAILED_BUSY);
    syncMicrophone();
    indicators.setBlinking(true);
    bleTransport.setPowerState(EchoBleProtocol::POWER_STATE_TURNING_OFF);
    Serial.printf("[Power] turning off: %u segments in PSRAM\n", buffer.memoryCount());
}

[[noreturn]] void turnOffNow() {
    Serial.println("[Power] off");
    bleTransport.setPowerState(EchoBleProtocol::POWER_STATE_OFF);
    const uint32_t startedMs = millis();
    while (bleTransport.powerStatePending() && millis() - startedMs < 300) {
        bleTransport.update(buffer);
        delay(5);
    }
    bleTransport.shutdown();
    delay(100);
    audio.end();
    indicators.setBlinking(false);
    // A 5 s hold turned it off: sleeping with the button down would wake it at once
    uint32_t releasedAtMs = millis();
    while (millis() - releasedAtMs < BUTTON_DEBOUNCE_MS) {
        if (digitalRead(BUTTON_PIN) == LOW) releasedAtMs = millis();
        delay(5);
    }
    Serial.flush();
    sleepNow();
}

/** One step a loop: BLE keeps running, so the phone can collect PSRAM meanwhile. */
void continueTurningOff() {
    if (photoSlot.isReady()) {
        bleTransport.cancelPhoto();
        photoSlot.discard();
    }
    if (powerOff.shouldSpill(buffer.hasCard())) {
        if (buffer.spillOldestToCard() == SegmentQueue::Spill::REFUSED) {
            powerOff.onCardRefused();
            Serial.println("[Power] the card took no more: waiting for the phone");
        } else {
            bleTransport.requestBufferStatus();
        }
    }
    if (powerOff.update(buffer.memoryCount()) == PowerOffPolicy::State::OFF_NOW) turnOffNow();
    delay(5);
}
```

- [ ] **Step 7: `main.ino`, `setup()`.**
  - Its first two lines, before `Serial.begin(115200);`:

```cpp
    checkButtonWake();
    setCpuFrequencyMhz(CPU_FREQ_MHZ);
```

  - After `bleTransport.setMicGainCallback(handleMicGain, nullptr);` add:

```cpp
    bleTransport.setPowerOffCallback(handlePowerOffCommand, nullptr);
```

  - Replace `if (!audio.begin()) fatal("[FATAL] Audio capture init failed");` with:

```cpp
    // Muted, the microphone stays off until listening resumes (syncMicrophone)
    if (!muteState.isMuted() && !audio.begin()) fatal("[FATAL] Audio capture init failed");
```

  - Change the boot log to `Serial.printf("[OK] System ready at %lu MHz\n", static_cast<unsigned long>(getCpuFrequencyMhz()));`, replacing `Serial.println("[OK] System ready — listening for speech\n");`.

- [ ] **Step 8: `main.ino`, `loop()`.**
  - After `bleTransport.update(buffer);` add:

```cpp
    const PowerRequest request = powerRequest;
    powerRequest = POWER_REQUEST_NONE;
    if (request != POWER_REQUEST_NONE) handlePowerOff(request == POWER_REQUEST_OFF);
```

  - Replace the button `switch` with:

```cpp
    // The button works muted too: a long press is also how listening resumes
    switch (button.update(digitalRead(BUTTON_PIN) == LOW, millis())) {
        case ButtonGesture::SHORT_PRESS:
            Serial.println("[Button] short press: photo");
            handleTakePhoto(nullptr);
            break;
        case ButtonGesture::LONG_PRESS:
            if (powerOff.state() == PowerOffPolicy::State::TURNING_OFF) {
                Serial.println("[Button] long press: keep Echo on");
                cancelPowerOff();
            } else {
                Serial.println("[Button] long press: mute toggle");
                handleMuteCommand(!muteState.isMuted(), nullptr);
            }
            break;
        case ButtonGesture::VERY_LONG_PRESS:
            Serial.println("[Button] very long press: turn off");
            handlePowerOff(true);
            break;
        case ButtonGesture::NONE:
            break;
    }
```

  - After the OTA block's closing `}` (the one ending `delay(5); return; }`), add:

```cpp
    if (powerOff.state() != PowerOffPolicy::State::ON) {
        continueTurningOff();
        return;
    }
```

  - Replace `if (muteState.isMuted()) {` and its body with:

```cpp
    if (muteState.isMuted() || micFailed) {
        if (state != STATE_IDLE || segmentPos != 0 || preBufferCount != 0) {
            discardInProgressCapture();
        }
        // A photo that finished after muting is dropped too
        if (muteState.isMuted() && photoSlot.isReady()) dropPhotoForPrivacy();

        delay(50);
        return;
    }
```

  `test_muted_gate_discards_capture_before_reading_audio` anchors on `if (muteState.isMuted())`. Once the condition changes, that text only matches `} else if (muteState.isMuted()) {` in `handleTakePhoto`, so the test would check the wrong block. In that test, change the anchor to the new condition:

```cpp
    const size_t muteBlockStart = source.find("if (muteState.isMuted() || micFailed)");
```

  - Frame timing. Right after `if (samplesRead <= 0) return;` add `const uint32_t frameStartedUs = micros();`. At the end of `loop()`, after the `switch (state)` block, add:

```cpp
    const uint32_t frameUs = micros() - frameStartedUs;
    if (frameUs > frameUsMax) frameUsMax = frameUs;
    frameUsTotal += frameUs;
    ++frameCount;
```

  - In `finalizeSegment()`, after the `Serial.printf("[Main] Segment ready: ...` line, add:

```cpp
    if (frameCount > 0) {
        Serial.printf("[Main] frame time avg=%lu us max=%lu us at %lu MHz\n",
                      static_cast<unsigned long>(frameUsTotal / frameCount),
                      static_cast<unsigned long>(frameUsMax),
                      static_cast<unsigned long>(getCpuFrequencyMhz()));
    }
    frameUsMax = 0;
    frameUsTotal = 0;
    frameCount = 0;
```

  Note that `finalizeSegment()` runs from inside the frame's `switch`, so the frame that finalizes is counted in the next segment's figures. That is harmless.

- [ ] **Step 9: Update the header comment.** At the top of `main.ino`, after item 8:

```cpp
 * 9. Muted, the microphone's driver is stopped. Turned off (app or a 5 s hold), Echo keeps
 *    what it was hearing, moves PSRAM to the card or waits for the phone, then deep-sleeps;
 *    a 1.5 s hold turns it on (power_off_policy.h, wake_gate.h)
```

- [ ] **Step 10: Build and test.**
  - `cd firmware; pio run -e xiao_esp32s3`. Expected: SUCCESS. If the `gpio_*`/`rtc_gpio_*` functions are undeclared, add `#include <driver/gpio.h>`.
  - `pio test -e native`. Expected: all suites PASS.

- [ ] **Step 11: Commit.**

```powershell
git add firmware/src/config.h firmware/src/audio_capture.h firmware/src/main.ino firmware/test/test_ble_transport_contract/test_main.cpp
git commit -m "firmware 0.10.0: 80 MHz, microphone off when muted, turn off and on" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 8: The app speaks the power frames

**Files:**
- Modify: `mobile/lib/services/device/device_protocol.dart`, `device_ble_port.dart`, `ble_service.dart`
- Modify (fakes): `mobile/test/services/device/device_controller_test.dart`, `mobile/test/screens/echo_device_screen_test.dart`, `mobile/test/screens/profile_screen_test.dart`
- Test: `mobile/test/services/device/device_protocol_test.dart`

- [ ] **Step 1: Write the failing test.** In `device_protocol_test.dart`, inside `group('DeviceProtocol', ...)`, add:

```dart
    test('turning off: POWER_OFF out, POWER_STATE in, from firmware 0.10.0', () {
      expect(DeviceProtocol.powerOff(), [0x1C, 1]);
      expect(DeviceProtocol.cancelPowerOff(), [0x1C, 0]);
      expect(DeviceProtocol.powerOffFirmware, '0.10.0');
      expect(DeviceProtocol.parsePowerState([0x24, 0, 0]), DevicePowerState.on);
      expect(DeviceProtocol.parsePowerState([0x24, 1, 0]), DevicePowerState.turningOff);
      expect(DeviceProtocol.parsePowerState([0x24, 2, 0]), DevicePowerState.off);
      expect(DeviceProtocol.parsePowerState([0x24, 3, 1]), DevicePowerState.refused);
      expect(DeviceProtocol.parsePowerState([0x24, 4, 0]), isNull);
      expect(DeviceProtocol.parsePowerState([0x24, 1]), isNull);
      expect(DeviceProtocol.parsePowerState([0x23, 1, 0]), isNull);
      expect(DeviceProtocol.supportedVersions, {2, 3, 4, 5, 6});
    });
```

- [ ] **Step 2: Run the test and confirm it fails.** `cd mobile; flutter test test/services/device/device_protocol_test.dart`. Expected: compile errors, `powerOff` and `DevicePowerState` undefined.

- [ ] **Step 3: Protocol.** In `device_protocol.dart`, after `enum OtaState { receiving, done, failed }`:

```dart
/// Where turning Echo off stands (POWER_STATE, firmware 0.10.0 on). Refused: Echo stays on
/// because it is updating.
enum DevicePowerState { on, turningOff, off, refused }
```

After `static const String micGainFirmware = '0.9.3';`:

```dart

  /// Turning Echo off from the app (firmware 0.10.0 on; no protocol bump).
  static const String powerOffFirmware = '0.10.0';
  static const int _framePowerOff = 0x1C;
  static const int framePowerState = 0x24;
```

After `takePhoto()`:

```dart

  static Uint8List powerOff() => Uint8List.fromList([_framePowerOff, 1]);

  static Uint8List cancelPowerOff() => Uint8List.fromList([_framePowerOff, 0]);

  /// POWER_STATE, or null for any other frame.
  static DevicePowerState? parsePowerState(List<int> bytes) {
    if (bytes.length != 3 || bytes.first != framePowerState) return null;
    return switch (bytes[1]) {
      0 => DevicePowerState.on,
      1 => DevicePowerState.turningOff,
      2 => DevicePowerState.off,
      3 => DevicePowerState.refused,
      _ => null,
    };
  }
```

- [ ] **Step 4: The port.** In `device_ble_port.dart`, after `Stream<DeviceInfo> get deviceInfoStream;`, add `Stream<DevicePowerState> get powerStateStream;`. After `Future<void> setMicGain(int gain);`, add:

```dart
  Future<void> powerOff();
  Future<void> cancelPowerOff();
```

- [ ] **Step 5: `BleService`.** After the `deviceInfoStream` getter:

```dart

  final _powerStateController = StreamController<DevicePowerState>.broadcast();

  @override
  Stream<DevicePowerState> get powerStateStream => _powerStateController.stream;
```

In `_onControlPacket`, after the `otaStatus` block:

```dart

    final powerState = DeviceProtocol.parsePowerState(value);
    if (powerState != null) {
      _powerStateController.add(powerState);
      return;
    }
```

After `setMicGain(...)`:

```dart

  @override
  Future<void> powerOff() => _writeControl(DeviceProtocol.powerOff());

  @override
  Future<void> cancelPowerOff() => _writeControl(DeviceProtocol.cancelPowerOff());
```

In `dispose()`, after `await _otaStatusController.close();`, add `await _powerStateController.close();`.

- [ ] **Step 6: The fakes.**
  - In `device_controller_test.dart`'s `_FakeDeviceBlePort`:
    - after `_infoController`, add `final _powerController = StreamController<DevicePowerState>.broadcast(sync: true);`;
    - after `int disposeCalls = 0;`, add `int powerOffWrites = 0;` and `int cancelPowerOffWrites = 0;`;
    - add these members:

```dart
  @override
  Stream<DevicePowerState> get powerStateStream => _powerController.stream;

  @override
  Future<void> powerOff() async => powerOffWrites++;

  @override
  Future<void> cancelPowerOff() async => cancelPowerOffWrites++;

  void emitPower(DevicePowerState state) => _powerController.add(state);
```

  - In `echo_device_screen_test.dart`'s `_FakeBlePort` (it answers as firmware 0.10.0 would), add:

```dart
  final _power = StreamController<DevicePowerState>.broadcast(sync: true);
  int powerOffs = 0;
  int cancelPowerOffs = 0;

  @override
  Stream<DevicePowerState> get powerStateStream => _power.stream;

  @override
  Future<void> powerOff() async {
    powerOffs++;
    _power.add(DevicePowerState.turningOff);
  }

  @override
  Future<void> cancelPowerOff() async => cancelPowerOffs++;
```

  - In `profile_screen_test.dart`'s `_FakeBlePort`, add:

```dart
  @override
  Stream<DevicePowerState> get powerStateStream => const Stream.empty();

  @override
  Future<void> powerOff() async {}

  @override
  Future<void> cancelPowerOff() async {}
```

  - Add `import 'package:echo_app/services/device/device_protocol.dart';` to any of these files that lacks it.
  - Then look for other implementers: `grep -rn "implements DeviceBlePort" mobile/test mobile/lib`. Give each one the same three members (`Stream.empty()` and no-ops).

- [ ] **Step 7: Run the tests and confirm they pass.** `flutter test test/services/device/` and then `flutter analyze --no-fatal-infos --no-fatal-warnings`. Expected: PASS, and no analyzer errors.

- [ ] **Step 8: Commit.**

```powershell
git add mobile/lib/services/device/device_protocol.dart mobile/lib/services/device/device_ble_port.dart mobile/lib/services/device/ble_service.dart mobile/test/services/device/device_protocol_test.dart mobile/test/services/device/device_controller_test.dart mobile/test/screens/echo_device_screen_test.dart mobile/test/screens/profile_screen_test.dart
git commit -m "app: POWER_OFF and POWER_STATE over BLE" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

Also add any other fake file you changed in Step 6.

---

### Task 9: `DeviceController` turns Echo off and knows it is off

Off, Echo disconnects. The controller keeps reconnecting in the background as it does today, so Echo reconnects by itself once it is turned on. Meanwhile it shows **off**, not "Reconnecting" or "Offline".

**Files:**
- Modify: `mobile/lib/models/device_status.dart`, `mobile/lib/services/device/device_controller.dart`
- Test: `mobile/test/services/device/device_controller_test.dart`

- [ ] **Step 1: Write the failing tests.** In `device_controller_test.dart`, inside the group, add:

```dart
    test('turning off is kept over telemetry; off is kept through the disconnect', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.scheduler.fire(0);
      await _flush();
      fixture.ble.emitPhase(DeviceBlePhase.ready);
      fixture.ble.emitTelemetry(_telemetry(bufferCount: 2));

      final turningOff = fixture.controller.turnOff();
      await _flush();
      expect(fixture.ble.powerOffWrites, 1);
      fixture.ble.emitPower(DevicePowerState.turningOff);
      await turningOff;
      expect(fixture.controller.state.connectionState, DeviceConnectionState.turningOff);

      fixture.ble.emitTelemetry(_telemetry(bufferCount: 1));
      expect(fixture.controller.state.connectionState, DeviceConnectionState.turningOff);
      expect(fixture.controller.state.bufferCount, 1);

      fixture.ble.emitPower(DevicePowerState.off);
      expect(fixture.controller.state.connectionState, DeviceConnectionState.off);
      fixture.ble.emitPhase(DeviceBlePhase.disconnected);
      await _flush();
      expect(fixture.controller.state.connectionState, DeviceConnectionState.off);

      // Turned on again: it reconnects and listens
      fixture.ble.emitPhase(DeviceBlePhase.ready);
      expect(fixture.controller.state.connectionState, DeviceConnectionState.listening);
    });

    test('a cancelled turn-off listens again, or stays muted', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.ble.emitTelemetry(_telemetry(muted: true));
      final turningOff = fixture.controller.turnOff();
      fixture.ble.emitPower(DevicePowerState.turningOff);
      await turningOff;

      await fixture.controller.cancelTurnOff();
      expect(fixture.ble.cancelPowerOffWrites, 1);
      fixture.ble.emitPower(DevicePowerState.on);
      expect(fixture.controller.state.connectionState, DeviceConnectionState.muted);
    });

    test('Echo refuses to turn off while updating', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.ble.emitTelemetry(_telemetry());

      final turningOff = fixture.controller.turnOff();
      fixture.ble.emitPower(DevicePowerState.refused);

      await expectLater(
        turningOff,
        throwsA(isA<StateError>().having(
            (error) => error.message, 'message', DeviceController.refusedUpdatingMessage)),
      );
      expect(fixture.controller.state.connectionState, DeviceConnectionState.listening);
    });
```

- [ ] **Step 2: Run the tests and confirm they fail.** `flutter test test/services/device/device_controller_test.dart`. Expected: compile errors, `turnOff` and `DeviceConnectionState.turningOff` undefined.

- [ ] **Step 3: The states.** In `device_status.dart`, add `turningOff,` and `off,` after `muted,` in `DeviceConnectionState`.

- [ ] **Step 4: The controller.** In `device_controller.dart`:
  - after `StreamSubscription<DeviceInfo>? _infoSubscription;`, add `StreamSubscription<DevicePowerState>? _powerSubscription;`;
  - after `DeviceInfo? _info;`, add:

```dart
  DevicePowerState _power = DevicePowerState.on;
  Completer<void>? _turnOffReply;

  static const refusedUpdatingMessage =
      'Echo is updating; turn it off when the update is done.';
```

  - In `start()`, after the `_infoSubscription` line, add `_powerSubscription = _ble.powerStateStream.listen(_onPowerState);`.
  - After `setMicGain(...)`, add:

```dart
  /// Echo finishes syncing, then turns off; its button turns it on. Completes once Echo
  /// has started, and throws a [StateError] it refused with ([refusedUpdatingMessage]).
  Future<void> turnOff() async {
    _ensureActive();
    final reply = Completer<void>();
    _turnOffReply = reply;
    final answered = reply.future.timeout(const Duration(seconds: 5));
    answered.ignore();
    try {
      await _ble.powerOff();
      await answered;
    } finally {
      if (identical(_turnOffReply, reply)) _turnOffReply = null;
    }
  }

  /// Keeps Echo on while it is still syncing.
  Future<void> cancelTurnOff() async {
    _ensureActive();
    await _ble.cancelPowerOff();
  }
```

  - In `dispose()`, after `await _infoSubscription?.cancel();`, add `await _powerSubscription?.cancel();`.
  - After `_onDeviceInfo(...)`, add:

```dart
  void _onPowerState(DevicePowerState power) {
    if (_disposed) return;
    final reply = _turnOffReply;
    if (power == DevicePowerState.refused) {
      if (reply != null && !reply.isCompleted) {
        reply.completeError(StateError(refusedUpdatingMessage));
      }
      return;
    }
    if (reply != null && !reply.isCompleted) reply.complete();
    _power = power;
    switch (power) {
      case DevicePowerState.on:
        if (_ready) _setConnectedState();
      case DevicePowerState.turningOff:
        _setConnectedState();
      case DevicePowerState.off:
        _setConnectionState(DeviceConnectionState.off);
      case DevicePowerState.refused:
        break;
    }
  }
```

  - Reset `_power = DevicePowerState.on;` in four places, so a fresh link never inherits "off":
    - `_onPhase`, `case DeviceBlePhase.ready:`, before `_ready = true;`;
    - `_attemptReconnect`, before `_ready = true;`;
    - `pair()`, before `_ready = true;`;
    - `forget()`, next to `_info = null;`.
  - In `_setConnectedState()`, add a local at the top:

```dart
    DeviceConnectionState connected(bool muted) => switch (_power) {
          DevicePowerState.turningOff => DeviceConnectionState.turningOff,
          DevicePowerState.off => DeviceConnectionState.off,
          DevicePowerState.on || DevicePowerState.refused =>
            muted ? DeviceConnectionState.muted : DeviceConnectionState.listening,
        };
```

    Then use `connected(false)` in place of `DeviceConnectionState.listening` in the `telemetry == null` branch, and `connected(telemetry.muted)` in place of the `telemetry.muted ? ... : ...` expression.
  - Replace `_setConnectionState` with:

```dart
  void _setConnectionState(DeviceConnectionState connectionState) {
    // Off, Echo is out of reach on purpose: not "reconnecting" or "offline"
    final shown = _power == DevicePowerState.off &&
            (connectionState == DeviceConnectionState.reconnecting ||
                connectionState == DeviceConnectionState.offline)
        ? DeviceConnectionState.off
        : connectionState;
    _setState(_state.copyWith(connectionState: shown, error: null));
  }
```

- [ ] **Step 5: Run the tests.** `flutter test test/services/device/device_controller_test.dart`. Expected: PASS. `flutter analyze` will now report non-exhaustive switches in the widgets; Task 10 fixes them, so do not commit a red analyze. Go on to Task 10 and commit both together.

---

### Task 10: Every screen says "Turning off" and "Off"

**Files:**
- Modify:
  - `mobile/lib/widgets/device_pill.dart`
  - `mobile/lib/widgets/device_instrument.dart`
  - `mobile/lib/screens/profile_screen.dart`
  - `mobile/lib/screens/settings/privacy_settings_screen.dart`
  - `mobile/lib/services/device/live_activity_service.dart`
  - `mobile/lib/services/app/app_lifecycle_coordinator.dart`
- Test:
  - `mobile/test/widgets/app_shell_test.dart`
  - `mobile/test/services/device/live_activity_service_test.dart`
  - `mobile/test/services/app/app_lifecycle_coordinator_test.dart`
- `widgets/today_sections.dart` needs nothing: its `_` arm already hides the problem panel for both states.

- [ ] **Step 1: Write the failing tests.**
  - `app_shell_test.dart`:
    - in the `DevicePill` `cases` map, add `DeviceConnectionState.turningOff: 'Turning off',` and `DeviceConnectionState.off: 'Off',`;
    - in `_spoken`, add `DeviceConnectionState.turningOff: 'Echo is turning off',` and `DeviceConnectionState.off: 'Echo is off',`.
  - `live_activity_service_test.dart`, at the end of `'the state follows the wearable'`:

```dart
    expect(
      LiveActivityState.from(const DeviceStatus(connectionState: DeviceConnectionState.off)),
      isNull,
    );
    expect(
      LiveActivityState.from(
        const DeviceStatus(connectionState: DeviceConnectionState.turningOff),
      )!
          .status,
      'muted',
    );
```

  - `app_lifecycle_coordinator_test.dart`, after `'starts controller and maps connected and disconnected states'`:

```dart
  test('turned off on purpose: no disconnected notification', () async {
    states.add(const DeviceStatus(connectionState: DeviceConnectionState.turningOff));
    states.add(const DeviceStatus(connectionState: DeviceConnectionState.off));
    await Future<void>.delayed(Duration.zero);
    expect(notificationPort.scheduledIds, isEmpty);
    expect(notificationPort.cancelledIds, contains(NotificationService.disconnectId));
  });
```

  (Use the same `states`/`notificationPort` fixtures as the neighbouring tests. If that file's tests set up per test in `setUp`, this test works as written.)

- [ ] **Step 2: Run the tests and confirm they fail.** Run `flutter test test/widgets/app_shell_test.dart test/services/device/live_activity_service_test.dart test/services/app/app_lifecycle_coordinator_test.dart`. Expected: the build fails on the non-exhaustive switches, or the new expectations fail.

- [ ] **Step 3: Implement.**
  - `device_pill.dart`, in `_look`, after the `muted` arm:

```dart
      DeviceConnectionState.turningOff => _PillLook(
          label: 'Turning off',
          spoken: 'Echo is turning off',
          dot: palette.amber),
      DeviceConnectionState.off => _PillLook(
          label: 'Off',
          spoken: 'Echo is off',
          dot: palette.onChromeMuted,
          hollow: true,
        ),
```

  - `device_instrument.dart`:
    - add the constructor parameter `this.onKeepOn,`;
    - add the field, documented as keeping Echo on while it is still syncing: `/// Keeps Echo on while it is still syncing.` then `final VoidCallback? onKeepOn;`;
    - in the label switch, after `muted`:

```dart
      DeviceConnectionState.turningOff => ('Turning off', palette.amber),
      DeviceConnectionState.off => ('Off', null),
```

    - in the action switch, after the `muted` arm:

```dart
      DeviceConnectionState.turningOff when onKeepOn != null => ('Keep Echo on', onKeepOn!),
```

    - in the label column, after the `waiting` block:

```dart
                    if (state == DeviceConnectionState.off) ...[
                      const SizedBox(height: 8),
                      Text("Hold Echo's button for 2 seconds to turn it on.",
                          style: textTheme.bodySmall),
                    ],
```

  - `profile_screen.dart`, in `stateLabel`, after `muted`:

```dart
        DeviceConnectionState.turningOff => 'Turning off',
        DeviceConnectionState.off => 'Off',
```

  - `privacy_settings_screen.dart`, in `microphoneStatus`, before `_`:

```dart
          DeviceConnectionState.turningOff || DeviceConnectionState.off => 'Off',
```

  - `live_activity_service.dart`:
    - in `from`, replace `DeviceConnectionState.unpaired => null,` with `DeviceConnectionState.unpaired || DeviceConnectionState.off => null,`;
    - add `DeviceConnectionState.turningOff => 'muted',` after the `muted` arm;
    - update the doc comment: `/// "listening", "muted" or "offline"; null: no Live Activity (nothing paired, or Echo off).`
  - `app_lifecycle_coordinator.dart`, in `_onStatus`, extend the first group:

```dart
      case DeviceConnectionState.listening:
      case DeviceConnectionState.muted:
      case DeviceConnectionState.turningOff:
      case DeviceConnectionState.off:
        unawaited(_notifications.cancelDisconnected());
```

- [ ] **Step 4: Run the tests and confirm they pass.** Run `flutter test` (the whole suite: the enum is everywhere), then `flutter analyze --no-fatal-infos --no-fatal-warnings`. Expected: all PASS, no errors.

- [ ] **Step 5: Commit Tasks 9 and 10 together.**

```powershell
git add mobile/lib/models/device_status.dart mobile/lib/services/device/device_controller.dart mobile/test/services/device/device_controller_test.dart mobile/lib/widgets/device_pill.dart mobile/lib/widgets/device_instrument.dart mobile/lib/screens/profile_screen.dart mobile/lib/screens/settings/privacy_settings_screen.dart mobile/lib/services/device/live_activity_service.dart mobile/lib/services/app/app_lifecycle_coordinator.dart mobile/test/widgets/app_shell_test.dart mobile/test/services/device/live_activity_service_test.dart mobile/test/services/app/app_lifecycle_coordinator_test.dart
git commit -m "app: Echo turning off and off, in every status" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 11: "Turn off Echo" on the Echo screen

**Files:**
- Modify: `mobile/lib/screens/echo_device_screen.dart`
- Test: `mobile/test/screens/echo_device_screen_test.dart`

- [ ] **Step 1: Write the failing tests.** After `'older firmware has no microphone gain'`, add:

```dart
  testWidgets('Turn off Echo asks first, from firmware 0.10.0', (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        firmwareVersion: '0.10.0',
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    final row = find.byKey(const Key('device-turn-off'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Turn off Echo?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.ble.powerOffs, 0);

    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
    await tester.pumpAndSettle();
    expect(fixture.ble.powerOffs, 1);
    expect(find.byKey(const Key('device-action-error')), findsNothing);
  });

  testWidgets('older firmware cannot be turned off from the app', (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        firmwareVersion: '0.9.3',
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    expect(find.byKey(const Key('device-turn-off')), findsNothing);
  });

  testWidgets('turning off: Keep Echo on cancels; off says how to turn it on', (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.turningOff,
        firmwareVersion: '0.10.0',
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    expect(find.byKey(const Key('device-turn-off')), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Keep Echo on'));
    await tester.pumpAndSettle();
    expect(fixture.ble.cancelPowerOffs, 1);

    fixture.emit(const DeviceStatus(
      connectionState: DeviceConnectionState.off,
      firmwareVersion: '0.10.0',
    ));
    await tester.pumpAndSettle();
    expect(find.text("Hold Echo's button for 2 seconds to turn it on."), findsOneWidget);
  });
```

  - If the instrument's action button is not a `FilledButton`, match its widget type: see `device-instrument-action` in `device_instrument.dart`, or use `find.byKey(const Key('device-instrument-action'))`.
  - If the fake's `_power` controller needs closing, close it in `_Fixture.dispose`.

- [ ] **Step 2: Run the tests and confirm they fail.** Run `flutter test test/screens/echo_device_screen_test.dart`. Expected: the new tests FAIL, because there is no `device-turn-off` row and no 'Keep Echo on'.

- [ ] **Step 3: Implement.** In `_EchoDeviceScreenState`:
  - after `bool _muteBusy = false;`, add `bool _turningOff = false;`;
  - after `_setMuted(...)`, add:

```dart
  /// Echo finishes syncing, then turns off; the instrument follows what Echo reports.
  Future<void> _turnOff() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Turn off Echo?'),
            content: const Text(
              'Echo will finish syncing, then turn off. '
              'Hold its button for 2 seconds to turn it on again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Turn off'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || _turningOff || !mounted) return;
    setState(() {
      _turningOff = true;
      _error = null;
    });
    try {
      await widget.deviceController.turnOff();
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Echo could not be turned off. Keep it nearby and try again.');
      }
    } finally {
      if (mounted) setState(() => _turningOff = false);
    }
  }

  Future<void> _keepOn() async {
    try {
      await widget.deviceController.cancelTurnOff();
    } catch (_) {
      if (mounted) setState(() => _error = 'Echo could not be kept on. Try again.');
    }
  }
```

  - in `build`, pass `onKeepOn: _keepOn,` to `DeviceInstrumentPanel`;
  - after `const SettingsSection('DEVICE'),`, before the Forget row:

```dart
            if (status.firmwareVersion != null &&
                !isNewerFirmware(DeviceProtocol.powerOffFirmware, status.firmwareVersion) &&
                (status.connectionState == DeviceConnectionState.listening ||
                    status.connectionState == DeviceConnectionState.muted))
              SettingsRow(
                key: const Key('device-turn-off'),
                icon: Icons.power_settings_new_rounded,
                title: _turningOff ? 'Turning off...' : 'Turn off Echo',
                onTap: _turningOff ? null : _turnOff,
              ),
```

  If `SettingsRow` has no `key` parameter, wrap it in a `KeyedSubtree(key: ..., child: ...)`.

- [ ] **Step 4: Run the tests and confirm they pass.** Run `flutter test test/screens/echo_device_screen_test.dart`, then `flutter test` and `flutter analyze --no-fatal-infos --no-fatal-warnings`. Expected: all PASS.

- [ ] **Step 5: Commit.**

```powershell
git add mobile/lib/screens/echo_device_screen.dart mobile/test/screens/echo_device_screen_test.dart
git commit -m "app: Turn off Echo, and Keep Echo on while it syncs" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 12: Docs

**Files:**
- Modify: `README.md` (only the button line), `docs/ROADMAP.md`

- [ ] **Step 1: README.** Replace

```
  wearable's button (a long press mutes): the wearable's camera
```

with

```
  wearable's button (released after a long press it mutes; held 5 s it turns Echo off, after
  syncing; held 2 s it turns it on again): the wearable's camera
```

`README.md` already has an unrelated uncommitted hunk (around line 505, `CORS_ORIGINS`), so stage only this hunk:

```powershell
git diff -U0 README.md > $env:TEMP\readme.patch
# Edit $env:TEMP\readme.patch: keep only the hunk for the button line, then
git apply --cached --unidiff-zero $env:TEMP\readme.patch
git diff --cached README.md   # must show only the button line
Remove-Item $env:TEMP\readme.patch
```

- [ ] **Step 2: ROADMAP.** In the "Consumi e spegnimento" entry (line 28), after the spec link, add `, [piano](superpowers/plans/2026-11-10-wearable-power-and-off.md)`. Then append a line to the entry:

```
      Codice pronto (firmware 0.10.0): da misurare sul dispositivo (checklist nella spec, "On the device").
```

Leave the box unchecked: the feature is done only once it has been measured on the hardware.

- [ ] **Step 3: Commit.**

```powershell
git add docs/ROADMAP.md
git commit -m "docs: turning Echo off, the button, and what is left to measure" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

(`README.md` is already staged from Step 1.)

---

## After the last task

- Run the whole suite once more:
  - `cd firmware; pio test -e native; pio run -e xiao_esp32s3`
  - `cd mobile; flutter analyze --no-fatal-infos --no-fatal-warnings; flutter test`
- `git status`: the unrelated files listed in Global constraints are still uncommitted and untouched.
- Do **not** push, and do not run `make firmware-release`. Tell the user the firmware is 0.10.0. Then hand over the hardware checklist in the spec ("On the device", items 1–6) for them to run: 80 MHz frame time from the `[Main] frame time` log, muted and off current, nothing lost across a turn-off, the button gestures, and the camera board.

