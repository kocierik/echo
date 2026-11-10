# Wearable power: a cooler chip, a real standby, and turning Echo off

Date: 2026-11-10. The hardware arrived (XIAO ESP32-S3 Sense, a 103040 1200 mAh LiPo, a printed
case). The user finds it big, and the chip is warm **all the time, even in silence** ("il circuito
scalda tanto"; where: the XIAO's chip side; when: always). The user asked to implement the power
optimizations found in the code and to turn the device on and off from the app, choosing both a
standby and a real power-off ("facciamo la 3"), plus power-off from the button ("button_off=true").
Everything researched on the way is kept here ("salva tutto nella doc").

## Intent

Echo should run cooler and last longer on the same battery, so that a smaller battery and a
smaller case become possible later. The user should be able to pause Echo from the app, and to
turn it off for the night or when it is not worn, without losing speech that has not reached the
phone yet.

## Goals

- **A cooler chip.** The CPU runs at 80 MHz instead of 240 MHz (160 MHz if Opus cannot keep up at
  80, measured on the device).
- **A real standby.** Muting (from the app or the button) stops the microphone's I2S driver, not
  only the reading of it. Resuming starts it again.
- **Off from the app.** "Turn off Echo" stops the microphone at once, then deep-sleeps once the
  speech waiting in PSRAM is safe: sent to the phone, or moved to the microSD card when one is in use.
- **Off from the button.** Holding the button for 5 s does the same.
- **On from the button.** Holding the button for 1.5 s wakes Echo; a shorter press puts it back
  to sleep, so it does not turn on in a pocket.
- **No false alarm.** The app shows Echo as "Off", not "disconnected", and reconnects by itself
  when Echo wakes.
- Firmware 0.10.0, still protocol 6. Older apps keep working with the new firmware (they never
  send the new frame and ignore the new notification); the app shows "Turn off Echo" only for
  firmware 0.10.0 on, as it does for the microphone gain (0.9.3).

## Non-goals

- Turning Echo **on** from the app: in deep sleep the radio is off, nothing can reach it.
- Waking on speech: hearing speech needs the microphone, which is what costs power.
- Bluetooth connection parameters (slower connection interval when idle): next step, only after
  the measurements below show how much the radio weighs.
- Powering the camera sensor down between photos: the Sense board does not wire its power-down
  pin. Measured first (with and without the camera board), handled in its own change if it matters.
- Porting to a Nordic chip, a smaller battery, a new case: decided after the measurements
  (see Background).
- Automatic light sleep (ESP-IDF power management): the always-on microphone keeps the chip awake
  almost all the time, and it needs a toolchain change.

## Anti-goals (a failure even if it works)

- Speech lost because Echo was turned off.
- Echo turning itself on in a pocket, or waking straight back up after being turned off.
- Dropped audio (I2S overruns) because the CPU is too slow for Opus.
- A "disconnected" notification for a device the user turned off.
- A muted Echo that comes back listening after being turned off and on.

## Design

### 1. CPU frequency

- `CPU_FREQ_MHZ` in `config.h`, default 80. `setCpuFrequencyMhz(CPU_FREQ_MHZ)` at the start of
  `setup()` (after the wake check, before anything is initialized), so every driver starts at
  the final frequency. On the S3 the APB clock stays at 80 MHz for any CPU
  frequency ≥ 80 MHz, so I2S, BLE and SPI timing do not change.
- The firmware measures the processing time of each 32 ms microphone frame (VAD + up to two 20 ms
  Opus frames + appending) and logs the maximum and the average once per segment. The criterion
  for keeping 80 MHz: the average is well under 32 ms and no I2S read ever returns short. The 8 DMA
  buffers (≈256 ms) absorb short spikes, not a steady deficit. If 80 MHz fails, 160 MHz.
- Photos and firmware updates run at the same frequency; both are checked on the device (photo
  time in the `[Camera] photo … in … ms` log, OTA transfer time). If one of them is too slow, the
  CPU goes to 240 MHz for its duration only.

### 2. Standby (mute)

- Entering mute (`handleMuteCommand`, the button, or the power-off sequence): discard the capture
  in progress (as today), then `audio.end()`.
- Leaving mute: `audio.begin()`, then `vad.reset()`. The first ≈160 ms after resuming are the
  driver's warm-up reads, already discarded by `begin()`.
- If `audio.begin()` fails, Echo stays muted (in RAM, not in NVS), logs the error and reports
  `muted` in DEVICE_STATUS: the app's instrument changes only on Echo's confirmation, so the user
  sees Echo still muted instead of a silently deaf Echo shown as listening.
- No protocol change: SET_MUTED and DEVICE_STATUS are unchanged.
- The mute state stays in NVS as today, so a muted Echo is still muted after being turned off and on.

### 3. Turning off

A small pure state machine, `PowerOffPolicy` (`power_off_policy.h`, native tests), owns the
decision; `main.ino` performs the effects.

States: `ON` → `TURNING_OFF` → `OFF_NOW`.

- **Request** (POWER_OFF from the app, or the 5 s button hold):
  - refused while a firmware update is in progress or the running firmware is on trial (not yet
    confirmed by the app): Echo replies `REFUSED_UPDATING` and stays on;
  - otherwise the microphone stops (without changing the saved mute state) and the state
    becomes `TURNING_OFF`. A segment being recorded is closed and stored, not discarded (turning
    off is not a privacy action, unlike mute). A photo being taken or waiting is dropped.
- **Making speech safe** while `TURNING_OFF`:
  - with the microSD card in use: the segments in PSRAM move to the card (a new
    `TieredQueue::spillOldestToCard()`, one segment per call so the loop keeps serving BLE,
    oldest first, the same move as `store()` on overflow, with
    the same move callback), then `OFF_NOW`. The
    card keeps them through deep sleep and the phone gets them after the next wake, oldest first;
  - if the card refuses (full or failing), or without a card: Echo waits until the PSRAM queue is
    empty, sending over BLE as usual, then `OFF_NOW`;
  - if the phone disconnects meanwhile, Echo stays in `TURNING_OFF` (microphone off, advertising)
    and finishes when the phone comes back. It never sleeps with speech only in PSRAM.
- **Cancel**: POWER_OFF with the cancel flag from the app, or a 1.5 s button hold, returns to `ON`
  and restores the microphone according to the saved mute state.
- **`OFF_NOW`**: Echo notifies POWER_STATE `OFF` (when connected), waits up to 300 ms for it to
  leave, disconnects, waits for the button to be released (else the wake pin is low and the chip
  wakes at once), enables the RTC pull-up on GPIO2, arms `ext0` wake on GPIO2 low, and calls
  `esp_deep_sleep_start()`.
- The app's DEVICE_STATUS keeps working during `TURNING_OFF`, so the app can show what is left.

### 4. Waking

- At boot, `esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_EXT0` means a button wake. Before
  anything else is started (no BLE, no microphone, no SD), the firmware polls the button: held for
  1.5 s since wake → a normal boot; released earlier → wait for release, then deep sleep again.
- Any other reset cause (power on, USB, a crash, an OTA restart) boots as today.
- After a wake Echo boots normally: the bond is in NVS, the phone sends SET_TIME again on connect
  (the transport already waits for it before sending), and segments on the card are sent first.
- PSRAM is lost in deep sleep by design: section 3 guarantees it holds nothing that matters.
- Charging works while Echo is off (the charger is hardware); plugging USB does not wake it.

### 5. The button

Today a long press fires at 1.5 s while held. With power-off at 5 s that would mute first, so:

- release before 1.5 s → short press: photo (unchanged);
- release between 1.5 s and 5 s → mute toggle, **on release**, instead of while held;
- held 5 s → power-off request, while held (fires once; releasing does nothing more).

`ButtonGesture` gains `VERY_LONG_PRESS` and a `veryLongPressMs`; `LONG_PRESS` moves to the
release. `BUTTON_POWER_OFF_MS 5000` in `config.h`. The trade-off: the user no longer feels the mute
happen while holding; it happens when they let go.

While `TURNING_OFF`, a 1.5 s hold cancels the power-off (section 3) instead of toggling mute.

### 6. Two new frames, protocol unchanged

Bumping the protocol would make every installed app reject the new firmware's frames (the app
checks the version in DEVICE_STATUS and DEVICE_INFO), so, as for SET_MIC_GAIN in 0.9.3, the
protocol stays at 6 and the app looks at the firmware version.

- `FRAME_POWER_OFF = 0x1C`, app → wearable, `[0x1C, action]`: `1` turn off, `0` cancel.
  Encrypted write, like every control frame. A firmware before 0.10.0 ignores it (unknown type).
- `FRAME_POWER_STATE = 0x24`, wearable → app, `[0x24, state, reason]`:
  - state `1` TURNING_OFF (reason 0), `2` OFF (Echo is about to sleep), `3` REFUSED, `0` ON
    (a power-off was cancelled);
  - reason for REFUSED: `1` updating firmware.
  Sent after every POWER_OFF and whenever the state changes, including a power-off started from
  the button. Apps before this change ignore it (unknown type on the control characteristic).

### 7. App

- `DeviceProtocol`: `powerOff()`, `cancelPowerOff()`, `parsePowerState()`;
  `powerOffFirmware = '0.10.0'`.
- `DeviceBlePort` / `BleService`: `powerOff()`, `cancelPowerOff()`, `powerStateStream`.
- `DeviceController`: `turnOff()`, `cancelTurnOff()`. Two new `DeviceConnectionState` values:
  `turningOff` (from POWER_STATE TURNING_OFF, kept over telemetry until ON or OFF) and `off`
  (from POWER_STATE OFF, kept through the disconnect and the reconnection attempts until Echo
  connects again).
- Profile → Echo (`echo_device_screen.dart`): a "Turn off Echo" row (firmware ≥ 0.10.0, listening
  or muted) with a confirmation: "Echo will finish syncing, then turn off. Hold its button for
  2 seconds to turn it on again." (2 s told to the user, 1.5 s in the firmware: a margin.) While
  turning off, the instrument says "Turning off" with a "Keep Echo on" action (cancel). When off:
  "Off", and "Hold Echo's button to turn it on".
- The device pill, the profile row and the privacy screen say "Off" / "Turning off". The Live
  Activity ends while Echo is off (as when nothing is paired) and shows "muted" while it is
  turning off: no change to the iOS widget.
- `app_lifecycle_coordinator.dart`: `off` and `turningOff` cancel the "disconnected" notification
  instead of scheduling it.
- `REFUSED` (updating firmware): "Echo is updating; turn it off when the update is done."
- Reconnection after a wake uses the existing auto-connect; nothing new.

## Testing

- Firmware, native (PlatformIO `native`, Unity), test-first:
  - `PowerOffPolicy`: request → `TURNING_OFF`; refused while updating or on trial; with a card
    → `OFF_NOW` once spilled; card refusing → waits for PSRAM to empty; disconnect while waiting
    stays `TURNING_OFF`; cancel → `ON`; the saved mute state is never changed by a power-off;
  - `ButtonGesture`: photo before 1.5 s; mute on release between 1.5 and 5 s; power-off at 5 s
    while held and nothing on release; debounce unchanged;
  - `TieredQueue::spillOldestToCard()` (one segment per call): oldest first, PSRAM empty after
    repeated calls, stops and reports when
    the card refuses, the move callback called for the segment being sent;
  - the wake decision (held 1.5 s → boot; released earlier → sleep), as a pure function;
  - protocol: POWER_OFF and POWER_STATE encode/decode; protocol version still 6.
- App (flutter test): the "Turn off Echo" flow and its confirmation, turning off and
  "Keep Echo on", "Off" in the device pill, no disconnect notification while off, the row hidden
  before firmware 0.10.0, POWER_STATE parsing.
- On the device (the user, with the hardware):
  1. before/after: chip temperature after 15 min of silence, at 240 and at 80 MHz (touch or a
     thermometer on the shield), and the encode-time log during speech;
  2. a full charge → empty run with the 1200 mAh battery, before and after, noting hours, minutes
     of speech and photos;
  3. if a meter on the battery line is available: current in silence, while speaking, muted, off;
  4. turn off with speech waiting, with and without a card: nothing lost after the wake;
  5. turn off from the button, release, wait 1 min: it stays off; short press: stays off;
     1.5 s hold: on;
  6. the camera board: silence current/temperature with and without it (power off before
     removing it).

## Background (research of 2026-11-10)

### The case and the battery

- Measured from the STL files: body 48.5 × 42.0 × 28.4 mm, lid 45.8 × 32.3 × 2.0 mm. The
  12.06 cm³ in the print quote is the volume of nylon, not the room inside.
- A 103040 cell is about 10 × 30 × 40 mm (check the seller's drawing: protection board and wires
  add to it). Indicative sizes of smaller cells, to be checked on the exact model:
  600 mAh ≈ 5–6 × 30 × 35–40 mm, 800 mAh ≈ 6–8 × 30 × 40 mm. A smaller cell mostly saves
  thickness, not area.

### How much Echo may draw (to be measured)

Provisional design range: 60–110 mA average, from the firmware's behaviour (microphone, VAD and
BLE always on; Opus and transfers while speaking; CPU at 240 MHz) and Seeed's ≈100 mA active figure
for the Sense ([Seeed](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/)), which was
measured in other conditions.

Runtime with a 20 % margin (`capacity × 0.8 / average current`):

| Battery | 60 mA | 80 mA | 110 mA |
|---|---:|---:|---:|
| 1200 mAh (current) | 16 h | 12 h | 8.7 h |
| 800 mAh | 10.7 h | 8 h | 5.8 h |
| 600 mAh | 8 h | 6 h | 4.4 h |

Average current needed for a target runtime, same margin:

| Battery | 8 h | 12 h |
|---|---:|---:|
| 600 mAh | ≤ 60 mA | ≤ 40 mA |
| 800 mAh | ≤ 80 mA | ≤ 53 mA |

The 800 mAh cell is the more prudent candidate; 600 mAh only once the listening current is measured
and lowered.

### Where the power goes, from the code (2026-11-10)

- CPU at the Arduino default of 240 MHz; no frequency or power management configured
  (`platformio.ini`, `main.ino`). Addressed by section 1.
- Mute stops reading the microphone (`delay(50)` in `loop()`), but the I2S driver keeps running:
  `AudioCapture::end()` exists and is never called. Addressed by section 2.
- BLE connection parameters are left to the stack and the phone (no request from the firmware;
  the app asks only for the MTU on Android). Deferred (non-goals).
- The camera driver is started for each photo and stopped after it, but the sensor stays powered:
  `camera_capture.h` says it "draws nothing between photos", which is not shown. Measured first.
- Opus: 32 kbit/s, complexity 3 (`opus_codec.h`), raised from 16 kbit/s to keep the voice's timbre
  for speaker recognition: not lowered. False VAD triggers in noise cost encoding and sending;
  checked with the real recordings of the VAD calibration, never by blindly raising the threshold.

### What competitors use (sources checked on 2026-11-10)

| Product | Hardware | Battery | Size | Runtime (claimed) | Camera |
|---|---|---|---|---|---|
| Omi Consumer (sold on omi.me) | Nordic nRF5340 + nRF7002 Wi-Fi, 2× TDK T5838 PDM mics, 512 MB NAND | 150 mAh | Ø 25.5 mm, 21 × 21 mm board | 10–14 h | No |
| Omi DevKit 2 (legacy) | XIAO nRF52840 Sense | 250 mAh | — | — | No |
| omiGlass (DIY glasses) | XIAO ESP32-S3 Sense, as Echo | DIY pack | — | "unvalidated" | Yes |
| PLAUD NotePin | not published | not published | 16.7 g | 20 h recording, 40 days standby | No |

- Omi: [open hardware](https://github.com/BasedHardware/omi/blob/main/docs/doc/hardware/consumer/index.mdx),
  [BOM](https://github.com/BasedHardware/omi/blob/main/omi/hardware/consumer/bom/README.md),
  [product page](https://www.omi.me/pages/product). The Consumer and DevKit firmware is Zephyr /
  nRF Connect SDK; omiGlass is Arduino/ESP-IDF: not interchangeable.
- PLAUD: [NotePin](https://www.plaud.ai/products/plaud-notepin); it records locally, which is not
  the same load as streaming to a phone.
- Limitless Pendant: no longer sold to new customers after Meta's acquisition (December 2025);
  no hardware specs published. Bee (Amazon): no hardware specs found.

Conclusion: Omi's size and runtime come from a dedicated low-power Nordic board without a camera,
not from a better-packed XIAO. The way to Omi's size is an audio-only Nordic pendant (photos from
the phone), which needs a firmware port; the alternative is keeping the camera and accepting a
bigger device. That choice waits for the measurements above.

## Calls I made (to check)

- 80 MHz first, 160 MHz as the fallback, decided by measurement, not by guess.
- Mute and standby are the same thing; no new "standby" in the protocol.
- With a card, turning off is immediate (speech moved to the card); without one, Echo waits for
  the phone. It never sleeps with speech only in PSRAM, even if that means staying in
  `TURNING_OFF` until the phone is back.
- Mute moves to the button's release (the price of a 5 s power-off on the same button).
- 1.5 s to wake, 5 s to turn off; turning off is refused only during a firmware update or trial.
- A muted Echo stays muted across off and on.
- Protocol unchanged (6): the new frames are gated on firmware 0.10.0, as the microphone gain was.
- After a button wake, Echo waits for the button to be released before starting, so the release
  is not read as a short press (a photo). The LED lights while it waits, to say "let go".
- The LED pin is held high (off) through deep sleep, so it does not glow or float.
