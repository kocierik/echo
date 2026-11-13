# The Pendant Hears Its Name, and a Spoken Request Travels Faster — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A spoken request to Echo (with a ready-made phrase such as "Hey Jarvis, …", chosen in Milestone C) is acknowledged by the pendant within about 0.3 s and reaches its answer sooner, without making anything that works today less reliable.

**Architecture:** The pendant gets a small wake word detector whose result is only a *hint*: it triggers instant feedback and marks the segment, while the server's transcript stays the only authority on whether Echo was addressed. The server transcribes the sentence just spoken before any backlog. Last, and only if measurements ask for it, a segment travels over BLE while it is being spoken, as an optimistic copy beside the existing reliable transfer.

**Tech Stack:** ESP32-S3 firmware (Arduino core 3.3.12 through PlatformIO `espressif32@8.0.0`, NimBLE, TensorFlow Lite Micro, microWakeWord model), Flutter app (flutter_blue_plus relay, just_audio), FastAPI backend (Redis queues, Postgres, alembic).

**Spec:** None was written. The decisions this plan argues from are in "Decisions and why" below; read that section first.

## Decisions and why

1. **The device's detection is a hint, never the authority.** The server keeps deciding with `find_wake` on the transcript (`backend/app/actions/voice.py`). A false detection costs one blink; a missed one falls back to today's path. This is what makes a self-trained, imperfect model acceptable.
2. **Engine: microWakeWord on TensorFlow Lite Micro.** Facts checked on 2026-11-12/13 in the installed toolchain and upstream:
   - The Arduino core's prebuilt ESP32-S3 libraries already contain `libespressif__esp-tflite-micro.a` (1.4.0) and `libespressif__esp-nn.a`, with headers under `include/espressif__esp-tflite-micro`.
   - A microWakeWord model is a `.tflite` file of tens of KB compiled into the firmware: no partition change, so it reaches the pendant by the normal update over BLE.
   - Stock models (`hey_jarvis`, `hey_mycroft`, `okay_nabu`, `alexa`) are Apache-2.0 in `github.com/esphome/micro-wake-word-models`; there is no "Echo" model. `hey_jarvis.json` (v2): probability cutoff 0.97, sliding window 5, feature step 10 ms, tensor arena 22,860 bytes. Training a custom phrase (`github.com/kahrendt/microWakeWord`) is left out: its README warns the basic notebook's result "will most likely not be usable" without experimentation. See decision 6.
   - Rejected: Espressif WakeNet. It is also in the prebuilt libraries (`libwakenet.a`, `esp_wn_iface.h`, model "Hi ESP"), but a custom word is a paid Espressif service, and its model needs a new flash partition (a USB flash, not an update over BLE). It stays the documented fallback of Task 3.
3. **No move to ESP-IDF in this plan.** Wake word detection does not need it (see 2). `espressif32@8.0.0` has no option to rebuild the core with a custom sdkconfig, so ESP-IDF would be a rewrite whose only gains are secure boot, flash encryption and anti-rollback. That is a security plan of its own.
4. **No streaming transcription to the server in this plan.** It is the largest change and its gain over Milestone D is about one second. Write that plan only if, after Milestone D, the time from the end of the sentence to its transcript is still above 2 s.
6. **The spoken phrase becomes a ready-made one; the product keeps the name Echo.** The user's decision of 2026-11-13: no custom training. "Echo" is a weak wake word (two syllables, "ecco" is everyday Italian, Amazon Echo is mentioned around). The candidates are the three official models of `esphome/micro-wake-word-models` `models/v2`, Apache-2.0, trained in English by microWakeWord's author: **Hey Jarvis**, **Hey Mycroft**, **Okay Nabu**. Excluded: Alexa (Amazon devices nearby, a mark of another assistant); the `experiments` models (their README: "minimally trained and tested", "at your own risk"); community models (no quality figures; everyday words such as "computer" or "wasabi"). The candidates are compared on the user's voice and on Echo's own recordings, and the user picks (Milestone C). "Ehi Echo" keeps working on the server throughout.
7. **The live copy never replaces the reliable transfer.** A segment sent while spoken (Milestone D) is also stored and sent the existing way unless the app confirms the upload. The server already ignores a second copy (`audio_hash` in `ingest_segment`).

## Global Constraints

- **Never** run `make deploy`, restart or recreate a production container, trigger `.github/workflows/ios-unsigned.yml`, run `make firmware-release`, read values in `.env`, or commit `firmware/signing/ota_private.pem`. Deploys, iOS builds, firmware releases and flashing are the user's steps, marked **USER** below. Stop at each one.
- **Never** change the `command:` of `redis` or `postgres` in `docker-compose.yml`.
- `api` and `worker` run the image's code, not the folder: new backend code is live only after the user's `make deploy`.
- Work in `/home/erik/echo` on `main`, one commit per task, with the repository's configured git identity. Write each commit message to a file and commit with `git commit -F <file>` (backticks in `-m` once ran a command). Subjects describe behaviour in a sentence, as the log does: `perf(voice): a spoken request is answered without its fixed waits`. Push at the end of a milestone, when its checks pass.
- Backend tests, from `/home/erik/echo`, one run at a time (two runs share the test database and fail each other):
  ```bash
  docker compose run --rm -T -e DATABASE_URL=postgresql+asyncpg://echo:echo@postgres:5432/echo_test -e REDIS_URL=redis://redis:6379/15 -e WHATSAPP_BRIDGE_URL=http://127.0.0.1:9 dev python -m pytest -q -p no:cacheprovider tests/ --deselect tests/test_core_runs.py::test_record_step_p95_stays_under_50_ms
  ```
  Lint: same prefix with `dev ruff check app tests evals`. Never `ruff --fix` on `alembic/`. Migrate the test database with the same environment and `dev python -m alembic upgrade head`.
- Firmware checks, from `/home/erik/echo`:
  ```bash
  docker run --rm -v "$PWD/firmware":/fw -w /fw -v echo-pio-cache:/root/.platformio python:3.11 sh -c "pip -q install platformio && pio test -e native && pio run -e xiao_esp32s3; s=\$?; chown -R $(id -u):$(id -g) /fw/.pio; exit \$s"
  ```
- App checks, from `/home/erik/echo/mobile` (2 analyzer infos exist already; do not run `dart format` on whole files):
  ```bash
  docker run --rm -v "$PWD":/app -w /app -v echo-pub-cache:/root/.pub-cache ghcr.io/cirruslabs/flutter:stable sh -c "flutter analyze; flutter test; chown -R $(id -u):$(id -g) /app"
  ```
- Wire compatibility, both directions, is a requirement of every firmware and app task: an older app with the new firmware and a newer app with an older firmware must keep recording, transferring and uploading exactly as today.
- Firmware logic that can be pure goes in its own header with a native test under `firmware/test/test_<name>/test_main.cpp`, as `wake_gate.h` and `power_off_policy.h` do. Native tests build as C++11.
- Do not copy source from ESPHome (its C++ is GPLv3). Write the detector from the TensorFlow Lite Micro API and the model's manifest.
- New hardware pins are off (`-1`) until soldered, as `BATTERY_DIVIDER_FITTED` is.

## Review Focus

1. **An older app meets the new firmware.** It must not see a frame it resets on: live frames go only to an app that asked (`FRAME_SET_LIVE`), and the wake flag rides in a segment id bit the old app treats as opaque. Pinned by Task 5 (id flag test) and Task 11 (no live without opt-in).
2. **The detector cannot start** (model rejected, no memory). Echo must listen and record as before, and a firmware on trial must not roll back for it. Pinned by Task 5 (`begin()` false is logged, never `fatal`).
3. **Mute or power-off during a request.** The capture is discarded: no feedback after it, no wake flag carried to the next segment, an open live stream is cancelled and nothing of it is uploaded. Pinned by Task 4 (`segmentEnded` clears) and Tasks 11 and 13 (cancel).
4. **Both copies of a segment reach the server.** One segment row, one answer. Pinned by Task 12 (same `recorded_at` on both paths) and Task 13 (server returns the existing segment).
5. **A backlog uploaded after hours away.** Its segments must not count as live speech, and a pendant clock that is ahead must not crash the rule. Pinned by Task 1.

---

## Milestone 0: Measure first (USER)

- [ ] **USER:** `make deploy` (everything since `e5d70d7`, with migration 042), then use Echo for a day.
- [ ] **USER or executor (read-only):** `docker compose logs --since 48h worker | grep "\[Voice\] Answered"`. Each line reads `… N s after the sentence ended (on the server after A s, transcribed after B s)`. Record the medians of `A`, `B - A` and `N - B` at the top of this file under a heading "Measured". They are the baseline every milestone is judged against. If `N - B` (the models) is the largest share, say so to the user: the next gain is in the answer path, which this plan does not touch.

---

## Milestone A: The server takes the sentence just spoken first

Backend only. Deployable on its own.

### Task 1: Live speech jumps the transcription queue

**Files:**
- Modify: `backend/app/routers/segments.py` (`_queue_stt_segment`, `ingest_segment`)
- Modify: `backend/app/workers/stt.py` (queue names, `process_stt`)
- Modify: `backend/app/main.py` (the health check's `llen("queue:stt")`)
- Test: `backend/tests/test_segments.py`, `backend/tests/test_stt_recovery.py` (or the file that already drives `process_stt`)

**Interfaces:**
- Produces: `LIVE_STT_QUEUE = "queue:stt:live"` in `workers/stt.py`; `LIVE_WINDOW = timedelta(seconds=30)` in `routers/segments.py`; `_queue_stt_segment(request, segment_id, *, live: bool = False)`.

A segment is live when `recorded_at + duration_ms >= now - LIVE_WINDOW`. A `recorded_at` in the future is live too. The router keeps a string literal for the queue name, as it does for `"queue:stt"`.

- [ ] **Step 1: Write the failing tests**, with the fixtures the neighbouring tests use:
  - `test_a_segment_just_spoken_is_queued_as_live`: ingest with `X-Recorded-At` = now − 5 s, `X-Duration-Ms` = 4000; assert its id is in `queue:stt:live` and not in `queue:stt`.
  - `test_a_backlog_segment_waits_its_turn`: `X-Recorded-At` = now − 10 min; assert the id is in `queue:stt` only.
  - `test_a_segment_from_a_clock_ahead_is_live`: `X-Recorded-At` = now + 2 min; status 201, id in `queue:stt:live`.
  - `test_live_speech_is_transcribed_before_the_backlog`: push one id on `queue:stt`, then one on `queue:stt:live`; run one iteration of `process_stt`; the live id is the one claimed.
- [ ] **Step 2: Run them, expect FAIL** (`-k "live or backlog or clock_ahead"`).
- [ ] **Step 3: Implement.** `brpop([LIVE_STT_QUEUE, STT_QUEUE, DEFERRED_STT_QUEUE], timeout=2)`; `late` stays true only for the deferred queue; a segment interrupted by shutdown goes back to `STT_QUEUE` as today. The duplicate-upload branch of `ingest_segment` passes the same `live` value. The health check adds the live queue's length to the same number.
- [ ] **Step 4: Run the whole backend suite and lint.** Expected: all pass.
- [ ] **Step 5: Commit** — `perf(stt): the sentence just spoken is transcribed before a backlog`.

### Task 2: A request to Echo does not wait for its voices to be split

**Files:**
- Modify: `backend/app/workers/stt.py` (`process_stt`, the `segment_turns` block)
- Test: `backend/tests/test_voice_requests.py` or the file that drives `process_stt`

`segment_turns` embeds each voice of the segment before the transcription is committed, so a request is queued for its answer only after it. A request to Echo is one voice, and the conversation is read whole again when it closes (`close_conversations`).

- [ ] **Step 1: Write the failing tests**
  - `test_a_request_to_echo_is_not_split_into_turns`: transcript `"Ehi Echo, che tempo fa domani"`, STT result with diarized words; patch `app.workers.stt.segment_turns` to raise `AssertionError`; after `process_stt`, the transcription exists, `turns is None`, and the id is on `queue:voice`.
  - `test_other_speech_is_still_split_into_turns`: transcript without the name; `segment_turns` is called once.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Compute the speaker-prefixed text before the turns block, and call `segment_turns` only when `find_wake(prefixed_text) is None`.
- [ ] **Step 4: Run the whole suite and lint.**
- [ ] **Step 5: Commit** — `perf(voice): a request to Echo is queued before its voices are split`.

- [ ] **USER:** `make deploy`. After a day, re-read the timing lines of Milestone 0 and note the change.

---

## Milestone B: The pendant hears its name (firmware 0.11.0, app, backend)

The detector ships compiled but **off** (`WAKE_WORD_ENABLED 0`) with a stock model. Milestone C turns it on.

### Task 3: Spike — the detector on the bench (throwaway, gate)

Not merged. Its only output is the "Spike result" paragraph added to this file.

**Files:** a scratch branch `spike/wake-word`; nothing kept.

- [ ] **Step 1:** Download the `.tflite` and `.json` of `hey_jarvis`, `hey_mycroft` and `okay_nabu` from `models/v2` of `github.com/esphome/micro-wake-word-models` (confirm the Apache-2.0 licence in the repository). Read each manifest: probability cutoff, sliding window size, feature step, tensor arena size.
- [ ] **Step 2:** Add the audio features library to `[env:xiao_esp32s3]` `lib_deps`. Expected: `kahrendt/ESPMicroSpeechFeatures`, pinned to an exact version found in the PlatformIO registry. If it is not there, vendor TensorFlow's Apache-2.0 `tensorflow/lite/experimental/microfrontend/lib` under `firmware/lib/microfrontend/`. Features: 16 kHz mono, 30 ms window, 10 ms step, 40 channels.
- [ ] **Step 3:** In a scratch `main.ino` change, compute the features once and run **all three** models on every frame after `amplify(...)`; print `[Wake] heard <model> p=<probability>` on each detection, and keep the existing `[Main] frame time avg=… max=…` log. Build with the firmware command.
- [ ] **Step 4: USER (pendant on USB):** flash, open the serial monitor at 115200. Say each phrase 20 times at arm's length, the way you would say it ("Hey Jarvis, …", "Hey Mycroft, …", "Okay Nabu, …"), half of them with a radio or TV on in the room. Then leave a radio talking for 10 minutes and say none. Paste the log.
- [ ] **Step 5: Gate.** All must hold at `CPU_FREQ_MHZ 80`:
  - the firmware links with the prebuilt TensorFlow Lite Micro and `firmware.bin` stays under 3,000,000 bytes (slots are 0x330000);
  - frame time with the three models running: `max` under 28,000 µs and `avg` under 20,000 µs of each 32 ms frame, while recording (Opus running). The shipped firmware runs one;
  - at least one phrase detected 16 or more times out of 20;
  - free heap after start is at least 60 KB.

  Record each phrase's count of 20 and its detections during the 10 minutes of radio: they are half of the user's choice in Milestone C.
  
  If only the frame time fails, repeat at `CPU_FREQ_MHZ 160` and report both to the user (160 MHz costs battery: their call). If linking fails, try the fallback below. Otherwise **stop and report**.
- [ ] **Step 6:** Write "Spike result" (numbers, library and version, anything surprising) at the top of this file and commit only that.

**Fallback (only if TensorFlow Lite Micro cannot be linked):** Espressif WakeNet through its C API, already in the prebuilt libraries: `esp_srmodel_init("model")`, `esp_srmodel_filter(models, ESP_WN_PREFIX, NULL)`, `esp_wn_handle_from_name(name)`, then `create(name, DET_MODE_95)`, `get_samp_chunksize`, `detect`. It needs a `model` data partition holding `esp_sr/srmodels.bin` (3.34 MB as shipped), so a custom partition table and a USB flash; a firmware updated over BLE on the old table must find no partition and run without detection. A custom word then depends on Espressif. Report to the user before taking this road.

### Task 4: When a detection counts — `wake_window.h`

**Files:**
- Create: `firmware/src/wake_window.h`
- Test: `firmware/test/test_wake_window/test_main.cpp`
- Modify: `firmware/src/config.h` (`#define WAKE_WINDOW_MS 4000`)

**Interfaces:**
- Produces:
  ```cpp
  class WakeWindow {
  public:
      explicit WakeWindow(uint32_t windowMs);
      void segmentStarted(uint32_t startedMs);  // the segment's start, pre-buffer included
      void segmentEnded();                      // finalized or discarded
      /** True once per segment: the name was detected in the segment's opening. */
      bool heard(bool detected, uint32_t nowMs);
      bool segmentHeard() const;                // this segment was marked
  };
  ```

The name counts only in the first `WAKE_WINDOW_MS` of a segment, matching the server's rule that it is among the first four words. A detection outside a segment is ignored.

- [ ] **Step 1: Write the failing tests**
  ```cpp
  void test_the_name_in_the_opening_counts_once() {
      WakeWindow w(4000);
      w.segmentStarted(10000);
      TEST_ASSERT_FALSE(w.heard(false, 10500));
      TEST_ASSERT_TRUE(w.heard(true, 10800));
      TEST_ASSERT_FALSE(w.heard(true, 10900));
      TEST_ASSERT_TRUE(w.segmentHeard());
  }
  void test_the_name_late_in_a_sentence_does_not_count() {
      WakeWindow w(4000);
      w.segmentStarted(10000);
      TEST_ASSERT_FALSE(w.heard(true, 14001));
      TEST_ASSERT_FALSE(w.segmentHeard());
  }
  void test_the_name_outside_a_segment_does_not_count() {
      WakeWindow w(4000);
      TEST_ASSERT_FALSE(w.heard(true, 500));
      w.segmentStarted(1000);
      TEST_ASSERT_FALSE(w.segmentHeard());
  }
  void test_a_discarded_segment_leaves_nothing_behind() {
      WakeWindow w(4000);
      w.segmentStarted(0);
      w.heard(true, 300);
      w.segmentEnded();
      TEST_ASSERT_FALSE(w.segmentHeard());
      w.segmentStarted(9000);
      TEST_ASSERT_TRUE(w.heard(true, 9400));
  }
  void test_the_window_survives_the_millis_wrap() {
      WakeWindow w(4000);
      w.segmentStarted(0xFFFFFF00U);
      TEST_ASSERT_TRUE(w.heard(true, 0x00000200U));
  }
  ```
- [ ] **Step 2: Run** `pio test -e native -f test_wake_window`, expect FAIL (no header).
- [ ] **Step 3: Implement** the class (unsigned subtraction for the elapsed time).
- [ ] **Step 4: Run** the native tests, expect PASS.
- [ ] **Step 5: Commit** — `feat(firmware): the name counts only in a sentence's opening`.

### Task 5: The detector in the firmware, off by default

**Files:**
- Create: `firmware/src/wake_detector.h`, `firmware/src/wake_model.h`
- Modify: `firmware/platformio.ini` (the library the spike chose), `firmware/src/config.h`, `firmware/src/ble_protocol.h`, `firmware/src/main.ino`
- Test: `firmware/test/test_ble_protocol/test_main.cpp`

**Interfaces:**
- Consumes: `WakeWindow` (Task 4); the spike's library and numbers (Task 3).
- Produces:
  ```cpp
  // wake_detector.h (device only)
  class WakeDetector {
  public:
      bool begin();                                    // false: no detection, Echo runs as before
      bool isReady() const;
      bool feed(const int16_t* samples, size_t count); // true when the name was detected in this call
      void reset();                                    // the microphone restarted
  };
  // wake_model.h: the .tflite as `alignas(16) const unsigned char WAKE_MODEL[]`, its length,
  // and from its manifest: WAKE_PROBABILITY_CUTOFF, WAKE_SLIDING_WINDOW, WAKE_TENSOR_ARENA_BYTES
  // ble_protocol.h
  constexpr uint32_t WAKE_SEGMENT_ID_FLAG = 0x40000000U;  // the pendant heard its name in this segment
  // config.h — inside #ifndef, so a bench build can pass -DWAKE_WORD_ENABLED=1
  #define WAKE_WORD_ENABLED 0   // 1 once the "Hey Echo" model passes its gate (Milestone C)
  ```
  A segment whose opening held the name is stored with `segmentId | WAKE_SEGMENT_ID_FLAG`. Later tasks read that bit.

Rules:
- `feed` takes the loop's 512-sample frames and keeps the remainder between calls (features step every 160 samples). It reads the model's input shape and quantization from the interpreter; a detection is the mean of the last `WAKE_SLIDING_WINDOW` probabilities above `WAKE_PROBABILITY_CUTOFF`.
- It is fed the amplified samples (after `amplify(pcmBuffer, samplesRead, micGain)`), on every frame while Echo listens, idle or recording: the features' noise estimate needs continuous audio.
- `setup()`: with `WAKE_WORD_ENABLED`, call `begin()` after `opusCodec.begin()`; on false print `[Wake] detector not started: listening without it` and go on. Never `fatal`.
- `loop()`: `wakeWindow.segmentStarted(segmentStartMs)` where a segment starts; `wakeWindow.segmentEnded()` at the end of `finalizeSegment()` and in `discardInProgressCapture()`; `wakeDetector.reset()` wherever `vad.reset()` follows a microphone restart (`syncMicrophone`). When `wakeWindow.heard(detected, millis())` is true, print `[Wake] heard` (Task 6 adds the feedback).
- `finalizeSegment()`: `segmentId = nextSegmentId++ | (wakeWindow.segmentHeard() ? WAKE_SEGMENT_ID_FLAG : 0)`, read before `segmentEnded()`.
- With `WAKE_WORD_ENABLED 0` none of this is compiled in and the build is byte-for-byte free of the model.

- [ ] **Step 1: Write the failing native tests** in `test_ble_protocol`
  ```cpp
  void test_the_wake_flag_is_not_the_photo_flag() {
      TEST_ASSERT_EQUAL_HEX32(0x40000000U, EchoBleProtocol::WAKE_SEGMENT_ID_FLAG);
      TEST_ASSERT_EQUAL_HEX32(0, EchoBleProtocol::WAKE_SEGMENT_ID_FLAG & EchoBleProtocol::PHOTO_SEGMENT_ID_FLAG);
  }
  void test_a_flagged_id_travels_whole_in_every_frame() {
      const uint32_t id = 7U | EchoBleProtocol::WAKE_SEGMENT_ID_FLAG;
      uint8_t frame[EchoBleProtocol::SEGMENT_START_SIZE];
      EchoBleProtocol::SegmentStart start = {id, EchoBleProtocol::PROTOCOL_VERSION, 10, 20, 1, 0};
      TEST_ASSERT_EQUAL(EchoBleProtocol::SEGMENT_START_SIZE,
                        EchoBleProtocol::encodeSegmentStart(start, frame, sizeof(frame)));
      EchoBleProtocol::SegmentStart back = {};
      TEST_ASSERT_TRUE(EchoBleProtocol::decodeSegmentStart(frame, sizeof(frame), back));
      TEST_ASSERT_EQUAL_HEX32(id, back.segmentId);
  }
  ```
  Add a third, in `test_segment_log` or `test_tiered_queue`: a segment stored with a flagged id is read back from the card log with the same id.
- [ ] **Step 2: Run, expect FAIL** (the constant does not exist).
- [ ] **Step 3: Implement** the constant, `wake_model.h` (the stock `hey_jarvis` model, generated with `xxd -i`, with its licence in a header comment), `wake_detector.h` and the `main.ino` changes.
- [ ] **Step 4: Check both builds.** Run the firmware command as is (`WAKE_WORD_ENABLED 0`): native tests pass, firmware builds, `firmware.bin` within 2 KB of its size before this task. Then build once with `-DWAKE_WORD_ENABLED=1` added on the command line of a scratch `platformio.ini` copy: it builds and stays under 3,000,000 bytes.
- [ ] **Step 5: Commit** — `feat(firmware): a wake word detector, off until its model is ready`.

### Task 6: Instant feedback, and the app is told

**Files:**
- Modify: `firmware/src/ble_protocol.h`, `firmware/src/ble_transport.h`, `firmware/src/indicators.h`, `firmware/src/config.h`, `firmware/src/main.ino`
- Test: `firmware/test/test_ble_protocol/test_main.cpp`

**Interfaces:**
- Produces:
  ```cpp
  // ble_protocol.h — wearable -> app on the control characteristic, firmware 0.11.0 on: [type].
  // Older apps ignore it (their control handler has no default case)
  constexpr uint8_t FRAME_WAKE_HEARD = 0x25;
  constexpr size_t WAKE_HEARD_SIZE = 1;
  inline size_t encodeWakeHeard(uint8_t* output, size_t capacity);
  // ble_transport.h
  void reportWakeHeard();            // sent on the next update(), dropped when not connected
  // indicators.h
  void pulse(uint16_t durationMs);   // the vibration motor, when fitted; never blocks
  // config.h
  #define WAKE_FLASH_MS 150
  #define WAKE_HAPTIC_MS 60
  #define FEEDBACK_LED_PIN -1   // an LED of its own (suggested: D3 / GPIO4, active high)
  #define HAPTIC_PIN -1         // a vibration motor through a transistor (suggested: D4 / GPIO5)
  ```

Rules:
- On a counted detection `main.ino` calls `indicators.flash(WAKE_FLASH_MS)`, `indicators.pulse(WAKE_HAPTIC_MS)` and `bleTransport.reportWakeHeard()`.
- `reportWakeHeard()` is sent like `notifyPowerState`, never during a firmware update, and is not kept for a later connection (stale feedback is worse than none).
- With `FEEDBACK_LED_PIN >= 0`, `Indicators` drives that pin (active high) instead of `LED_PIN`, and `release()` no longer silences it: the LED works with a microSD mounted. With `-1` nothing changes: GPIO21 is never driven once the card owns it.
- With `HAPTIC_PIN >= 0`, `begin()` sets it as an output held low and `update()` ends the pulse; with `-1`, `pulse` does nothing.

- [ ] **Step 1: Write the failing native test**
  ```cpp
  void test_wake_heard_is_one_byte() {
      uint8_t frame[2] = {0, 0xEE};
      TEST_ASSERT_EQUAL(1, EchoBleProtocol::encodeWakeHeard(frame, sizeof(frame)));
      TEST_ASSERT_EQUAL_HEX8(0x25, frame[0]);
      TEST_ASSERT_EQUAL_HEX8(0xEE, frame[1]);
      TEST_ASSERT_EQUAL(0, EchoBleProtocol::encodeWakeHeard(frame, 0));
      TEST_ASSERT_EQUAL(0, EchoBleProtocol::encodeWakeHeard(nullptr, 1));
  }
  ```
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the frame, the transport's pending notice, the indicator changes and the three calls in `main.ino`.
- [ ] **Step 4: Run the firmware command.** Expected: native tests pass, both builds of Task 5 Step 4 still build.
- [ ] **Step 5: Commit** — `feat(firmware): Echo shows at once that it heard its name`.

### Task 7: The app marks the segment and sounds in headphones

**Files:**
- Modify: `mobile/lib/services/device/device_protocol.dart`, `ble_packet_assembler.dart`, `ble_service.dart`, `mobile/lib/services/api/wearable_api.dart`, `mobile/lib/services/phone/answer_speaker.dart`, and where `AnswerSpeaker` and `BleService` are wired together
- Create: `mobile/assets/sounds/heard.wav` (120 ms, 880 Hz sine, 10 ms fades, 16 kHz mono; generate it once with Python's `wave` module, do not commit the generator), registered in `pubspec.yaml`
- Test: `mobile/test/services/device/device_protocol_test.dart`, `ble_packet_assembler_test.dart`, `mobile/test/services/answer_speaker_test.dart`

**Interfaces:**
- Consumes: `FRAME_WAKE_HEARD = 0x25`, `WAKE_SEGMENT_ID_FLAG = 0x40000000`.
- Produces: `DeviceProtocol.isWakeHeard(List<int> value)`; `BleCompletedSegment.wakeHeard` (the id carries the flag and it is not a photo); `BleService.onWakeHeard` (`void Function()?`); `uploadSegment(..., bool wakeHeard = false)` sending header `X-Wake-Heard: 1` only when true; `abstract interface class Earcon { Future<void> play(); }` and `AnswerSpeaker.heard()`.

Rules:
- The id is used whole, flag included, everywhere it already is (acks, `UPLOAD_OK`).
- `heard()` plays the earcon only when Spoken answers is not off **and** `headphones()` is true, never while `quiet` (dictation). Never on the phone's speaker: the pendant would record the tone inside the request. It never throws and does not mute Echo.

- [ ] **Step 1: Write the failing tests**
  - `device_protocol_test`: `isWakeHeard([0x25])` is true; `[0x25, 0]`, `[0x24, 0, 0]` and `[]` are false.
  - `ble_packet_assembler_test`: a complete audio segment with id `0x40000007` gives `wakeHeard == true` and `id == 0x40000007`; id `7` gives false; a photo with id `0xC0000001` gives false.
  - `answer_speaker_test`: `heard()` plays once with headphones and setting `headphones` or `always`; plays nothing with no headphones, with setting `off`, or while `quiet`; a throwing `Earcon` does not throw out of `heard()`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** `_onControlPacket` checks `isWakeHeard` before the `switch` and calls `onWakeHeard`; the just_audio `Earcon` plays the asset.
- [ ] **Step 4: Run the app checks.** Expected: tests pass, the same 2 analyzer infos.
- [ ] **Step 5: Commit** — `feat(app): a tone in headphones when Echo hears its name`.

### Task 8: The server records what the pendant heard

**Files:**
- Create: `backend/alembic/versions/043_segments_wake_heard.py`
- Modify: `backend/app/models/segment.py`, `backend/app/routers/segments.py`, `backend/app/workers/voice_requests.py` (`_timing`), `docs/schema.sql`, `backend/tests/test_migrations.py` (`range(1, 44)`)
- Test: `backend/tests/test_segments.py`, `backend/tests/test_voice_requests.py`

**Interfaces:**
- Consumes: header `X-Wake-Heard: 1` (Task 7).
- Produces: `segments.wake_heard BOOLEAN NOT NULL DEFAULT false`; the timing line ends `…, pendant heard the name: yes)` or `no`.

This column is the field measurement of the model: requests the transcript confirms but the pendant missed, and the reverse.

- [ ] **Step 1: Write the failing tests**
  - `test_ingest_records_that_the_pendant_heard_its_name`: with `X-Wake-Heard: 1` the row has `wake_heard is True`; without the header, or with `0`, `False`.
  - `test_the_timing_line_says_whether_the_pendant_heard`: `_timing(segment)` contains `pendant heard the name: yes` for a segment with `wake_heard=True`, `no` otherwise.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** The migration uses alembic helpers with an existence check, as 042 does. Migrate the test database.
- [ ] **Step 4: Run the whole suite and lint.**
- [ ] **Step 5: Commit** — `feat(voice): each request records whether the pendant heard its name`. Push the milestone.

- [ ] **USER:** `make deploy` (migration 043) and start an iOS build. The firmware stays unreleased until Milestone C.

---

## Milestone C: Echo answers to a ready-made phrase

No training (decision 6). The user picks one of `hey_jarvis`, `hey_mycroft`, `okay_nabu` from two numbers: how often the pendant hears it when said (Task 3, Step 4) and how often it fires on Echo's real recordings, where nobody said it (Task 9).

### Task 9: How often each candidate fires in Echo's real life

**Files:**
- Create: `backend/app/cli/export_wake_eval.py`, `firmware/tools/wake_eval.py`
- Modify: `.gitignore` (`backend/.wake_eval/`)
- Test: `backend/tests/test_export_wake_eval.py`

**Interfaces:**
- Produces: `python -m app.cli.export_wake_eval --out /app/.wake_eval [--user <id>] [--limit 2000]` writing 16 kHz mono WAV files (`segment_to_wav`) of completed, transcribed segments, newest first, and `labels.csv` with columns `file,recorded_at,duration_ms`. A segment whose transcript contains `jarvis`, `mycroft` or `nabu` (case-insensitive) is skipped: everything exported is audio where none of the candidates was said. `python wake_eval.py --model <tflite> --manifest <json> --data <dir> [--cutoff 0.9 0.95 0.97]` printing, per cutoff, the false detections per hour of exported audio and the files that fired.

- [ ] **Step 1: Write the failing test** `test_export_keeps_only_audio_without_a_candidate`: three transcribed segments ("andiamo a casa", "hey Jarvis accendi la luce", "Ehi Echo, che ore sono"); the export writes two WAV files (the first and the third) and two rows in `labels.csv`.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement the export. Step 4: Run, expect PASS; whole suite and lint.**
- [ ] **Step 5: Write `wake_eval.py`.** It must compute the same features and decision as the pendant (cutoff and sliding window from the manifest). Prefer the `pymicro-wakeword` package (confirm it on PyPI); otherwise `pymicro-features` with a TFLite interpreter. Self-check at the bottom of the script: an empty folder gives 0 hours and no division by zero.
- [ ] **Step 6: USER approval, then export.** The export copies the user's recordings to `backend/.wake_eval/` on the server. Ask first. Then:
  ```bash
  docker compose run --rm -T --no-deps dev python -m app.cli.export_wake_eval --out /app/.wake_eval
  ```
  (`--no-deps`: never let this command touch the running `redis` or `postgres`.)
- [ ] **Step 7: Score the three candidates** in a throwaway `python:3.11` container, at each manifest's own cutoff and one step either side. Report a table: phrase, hours of audio, false detections per hour, and (from Task 3) detections out of 20 and during the radio.
- [ ] **Step 8: Commit** — `chore(wake): how often each wake phrase fires in Echo's own recordings`. The recordings are never committed.
- [ ] **USER: choose the phrase.** Recommended rule: the most detections out of 20 among the phrases with at most 0.5 false detections per hour. The user may override it (how the phrase feels to say counts).

### Task 10: Echo answers to the chosen phrase

**Files:**
- Modify: `backend/app/actions/voice.py` (`_WAKE`, `_DIRECT`, `ASSISTANT_CHECK_PROMPT`, the comments above them), `backend/app/services/transcription_enhancer.py` (the phrase's name always among the keyterms), the "Ehi Echo" examples in `backend/app/services/analysis_pipeline.py` (prompt, around line 352), `backend/app/services/retranscription.py`, `backend/app/actions/todo_tools.py`, `backend/app/workers/voice_requests.py`
- Modify (app): `mobile/lib/screens/onboarding/first_result_step.dart` (`firstRequests`), `mobile/lib/screens/settings/routines_screen.dart`, `mobile/lib/screens/settings/capabilities_screen.dart`, `mobile/lib/services/phone/answer_speaker.dart`
- Modify (site): `site/index.html` only; `site/app/**` is a build output
- Modify (firmware): `firmware/src/wake_model.h` (the chosen model, if not `hey_jarvis`), `firmware/src/config.h` (`WAKE_WORD_ENABLED 1`, version 0.11.0)
- Modify: `docs/DEVELOPMENT.md` (a "Wake word" section: the phrase, where the model comes from, how to score another with `wake_eval.py`)
- Test: `backend/tests/test_voice_requests.py` (or the file that tests `find_wake`), `backend/tests/test_stt_learned.py`, the app tests that assert the onboarding examples

**Interfaces:**
- The spellings the server accepts, per phrase. The greeting is required for the phrase to be a direct address (`is_direct_address`); the name alone, in the first four words, is a candidate that goes through `is_assistant_request`, as a bare "Echo" does today:

  | Model | Greeting | Name |
  |---|---|---|
  | `hey_jarvis` | `hey\|hei\|ehi\|ehy\|ei` | `jarvis\|giarvis\|jervis` |
  | `hey_mycroft` | `hey\|hei\|ehi\|ehy\|ei` | `mycroft\|maicroft\|my croft` |
  | `okay_nabu` | `okay\|ok\|okey\|okei\|ochei` | `nabu` |

- Every rule for "Echo" stays as it is, "ecco" included: both phrases work while the user changes habit.

- [ ] **Step 1: Write the failing tests** (shown for `hey_jarvis`; use the chosen phrase):
  - `test_the_new_phrase_is_a_direct_request`: `is_direct_address("[You] Hey Jarvis, che tempo fa domani")` is true; `find_wake` of `"Hey Jarvis, che tempo fa domani"` points at `"che"`.
  - `test_italian_spelling_of_the_new_phrase`: `"Ehi Giarvis, accendi la luce"` is a direct request.
  - `test_the_name_inside_a_sentence_is_a_mention`: `find_wake("ieri ho rivisto il film con Jarvis e Tony")` is None.
  - `test_echo_still_works_during_the_change`: `"Ehi Echo, che ore sono"` is still a direct request (the existing Echo tests stay unchanged and green).
  - `test_the_phrase_is_always_a_keyterm`: the STT context's keyterms contain `"Jarvis"` for a user with no people or learned words.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the server side, then replace "Ehi Echo"/"Hey Echo" in the app, site and prompt examples with the chosen phrase (the product name "Echo" stays everywhere else). The voice enrollment text does not name the phrase and is unchanged.
- [ ] **Step 4: Firmware.** Put the chosen model in `wake_model.h`, set `WAKE_WORD_ENABLED 1` and version 0.11.0, run the firmware command. Expected: native tests pass, firmware builds under 3,000,000 bytes.
- [ ] **Step 5: Run the backend suite and lint, then the app checks.**
- [ ] **Step 6: Commit** — `feat(voice): Echo answers to "Hey Jarvis", heard on the pendant` (with the chosen phrase). Push.
- [ ] **USER:** `make deploy`, an iOS build, `make firmware-release NOTES="…"`, update the pendant from the app, then say the phrase with a request ten times: the LED (no card, or an LED on its own pin) or the tone in headphones answers within a moment. After some days, compare `wake_heard` with the transcripts (for `hey_jarvis`):
  ```sql
  SELECT s.wake_heard, count(*) FROM segments s JOIN transcriptions t ON t.segment_id = s.id
  WHERE s.recorded_at > now() - interval '7 days' AND t.text ~* '(ehi|hey|hei|ehy|ei)[ ,.!]+(jarvis|giarvis|jervis)'
  GROUP BY 1;
  ```

---

## Milestone D: A segment reaches the phone while it is spoken (firmware 0.12.0, app)

**Gate (USER, with the timing lines):** do this milestone only if the median "on the server after" is 2.0 s or more after Milestones A to C. It removes the BLE transfer that today starts when the sentence ends: about 1 s for a short request, more for a long one.

Wire format, on the audio characteristic, wearable → app, **only** after the app sent `FRAME_SET_LIVE` with 1 on this connection (an older app resets its transfer on an unknown audio frame). All integers little-endian.

| Frame | Type | Layout | Size |
|---|---|---|---|
| `FRAME_LIVE_START` | `0x05` | type, liveId u32 | 5 |
| `FRAME_LIVE_DATA` | `0x06` | type, liveId u32, sequence u16, bytes | 7 + n |
| `FRAME_LIVE_END` | `0x07` | type, liveId u32, segmentId u32, totalLength u32, durationMs u32, crc u32, recordedAtUnixSeconds u64, silenceBeforeMs u32, avgEnergy u16 | 35 |
| `FRAME_LIVE_CANCEL` | `0x08` | type, liveId u32 | 5 |
| `FRAME_SET_LIVE` (app → wearable, control) | `0x1D` | type, 0 or 1 | 2 |

`liveId` is the segment's id without the wake flag, known when the segment starts; `segmentId` in `END` is the id the segment is stored under (flag included), the one `UPLOAD_OK` must carry. `sequence` starts at 0. `crc` and `totalLength` cover the same bytes as the stored segment.

### Task 11: The live stream's state, and its frames

**Files:**
- Create: `firmware/src/live_stream_state.h`
- Modify: `firmware/src/ble_protocol.h` (the five frames, their sizes, encoders, `FRAME_SET_LIVE` in `decodeControlFrame` with `ControlFrame::live`)
- Test: `firmware/test/test_live_stream_state/test_main.cpp`, `firmware/test/test_ble_protocol/test_main.cpp`

**Interfaces:**
- Produces:
  ```cpp
  constexpr uint32_t LIVE_CONFIRM_TIMEOUT_MS = 8000;
  class LiveStreamState {
  public:
      enum class Phase : uint8_t { IDLE, OPEN, AWAITING_CONFIRM };
      void setEnabled(bool enabled);     // FRAME_SET_LIVE; false again on every disconnect
      /** A segment starting now may go live: enabled, link ready, nothing sending or waiting. */
      bool canOpen(bool linkReady, bool transferActive, uint16_t queued) const;
      void open(uint32_t liveId);
      uint16_t nextSequence();           // 0, 1, 2…
      void cancel();                     // discarded, or it could not be finished in time
      void end(uint32_t segmentId, uint32_t nowMs);
      /** The reliable transfer of `segmentId` waits: its live copy may still be confirmed. */
      bool holds(uint32_t segmentId, uint32_t nowMs);
      bool confirm(uint32_t segmentId);  // UPLOAD_OK for the held segment
      void disconnected();
      Phase phase() const;
      uint32_t liveId() const;
  };
  ```

- [ ] **Step 1: Write the failing tests**
  - `test_nothing_goes_live_until_the_app_asks`: `canOpen(true, false, 0)` is false; after `setEnabled(true)` true; after `disconnected()` false again.
  - `test_live_needs_an_idle_link_and_an_empty_queue`: enabled; `canOpen(false, false, 0)`, `canOpen(true, true, 0)` and `canOpen(true, false, 1)` are false.
  - `test_the_reliable_copy_waits_for_the_confirmation`: `open(7)`, `end(0x40000007, 1000)`; `holds(0x40000007, 1000)` and `holds(0x40000007, 8999)` are true, `holds(0x40000007, 9000)` is false and the phase is IDLE; `holds(8, 1000)` is false.
  - `test_a_confirmation_ends_the_wait`: after `end(9, 0)`, `confirm(8)` is false, `confirm(9)` is true, then `holds(9, 1)` is false.
  - `test_a_cancelled_stream_holds_nothing`, `test_a_disconnect_releases_the_segment`, `test_sequences_restart_with_each_stream`.
  - Protocol: each encoder writes the sizes in the table (5, 7, 35, 5) and the fields at the stated offsets; `decodeControlFrame` accepts `{0x1D, 0}` and `{0x1D, 1}`, rejects `{0x1D, 2}` and a 1-byte `{0x1D}`.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement. Step 4: Run native tests, expect PASS.**
- [ ] **Step 5: Commit** — `feat(firmware): the frames and state of a segment sent while spoken`.

### Task 12: The firmware sends the segment as it is recorded

**Files:**
- Modify: `firmware/src/ble_transport.h`, `firmware/src/main.ino`, `firmware/src/config.h` (version 0.12.0, `#define LIVE_FLUSH_BUDGET_MS 200`)

**Interfaces:**
- Consumes: `LiveStreamState`, the frame encoders (Task 11).
- Produces, on `BleTransport`:
  ```cpp
  bool beginLive(uint32_t liveId, const SegmentQueue& buffer);  // sends LIVE_START when canOpen
  void feedLive(const uint8_t* data, size_t length);            // sends what is new, never blocks
  bool endLive(const BufferedSegment& stored, const uint8_t* data);  // rest + LIVE_END in budget
  void cancelLive();                                            // LIVE_CANCEL, best effort
  ```

Rules:
- `main.ino` takes the segment's id when the segment starts (`liveId = nextSegmentId++`) and uses it at `finalizeSegment()` instead of taking a new one. An empty or discarded segment wastes an id; that is fine.
- At a segment's start: `beginLive(liveId, buffer)`. While recording, after each `encodeFrame`: `feedLive(segmentBuffer, segmentPos)`. In `discardInProgressCapture()`: `cancelLive()`.
- In `finalizeSegment()`, after the segment is stored in the queue: `endLive(header, segmentBuffer)`. It sends the bytes not yet sent and `LIVE_END` within `LIVE_FLUSH_BUDGET_MS`; if it cannot, it sends `LIVE_CANCEL` and returns false. A segment that was not stored is cancelled.
- `recordedAtUnixSeconds` in `LIVE_END` comes from the same `resolveRecordedAt(...)` call the reliable `SEGMENT_METADATA` uses, so both copies carry the same time (the server's duplicate check hashes it).
- While a stream is `OPEN`, `update()` starts no photo and no segment transfer. While `holds(head id, millis())` is true, `update()` does not begin the reliable transfer of the queue's head. `acceptUpload` for a held id that is the queue's head removes it from the queue (`confirm`). Timeout or disconnect: the reliable transfer starts as today.
- `feedLive` uses `notifyAudio` with a 5 ms budget per call and payloads of at most `segmentDataPayloadSizeForMtu(...)`; a refused notification is retried at the next call, from the same byte.
- `FRAME_SET_LIVE` calls `setEnabled`; every disconnect calls `disconnected()`.

- [ ] **Step 1: Implement** as above. The decisions are already covered by Task 11's native tests; this task has no new pure logic.
- [ ] **Step 2: Run the firmware command.** Expected: native tests pass, firmware builds.
- [ ] **Step 3: Self-review against Review Focus 1, 3 and 4**: no live frame can be sent before `FRAME_SET_LIVE`; mute cancels; both copies carry one `recorded_at`. Write one line for each in the commit body saying where the code guarantees it.
- [ ] **Step 4: Commit** — `feat(firmware): a segment reaches the phone while it is spoken`.

### Task 13: The app receives the live copy

**Files:**
- Create: `mobile/lib/services/device/ble_live_assembler.dart`
- Modify: `mobile/lib/services/device/ble_service.dart`, `device_protocol.dart` (`liveFirmware = '0.12.0'`, `buildSetLive(bool)`), and where the mic gain is gated on `micGainFirmware` (send `FRAME_SET_LIVE` the same way, when DEVICE_INFO reports 0.12.0 or later)
- Test: `mobile/test/services/device/ble_live_assembler_test.dart`, `device_protocol_test.dart`; `backend/tests/test_segments.py`

**Interfaces:**
- Consumes: the wire format above.
- Produces:
  ```dart
  class BleLiveAssembler {
    static bool handles(int type);              // 0x05..0x08
    BleCompletedSegment? add(List<int> packet); // the segment at a valid END, else null
  }
  ```
  A completed live segment is handed to the relay as `BleSegmentCompleted`, so it is uploaded and confirmed with `UPLOAD_OK(segmentId)` exactly like any other.

Rules:
- Any inconsistency (a frame without a start, a sequence gap, another `liveId`, a wrong length or CRC, a `CANCEL`) drops the live copy silently: no restart request, no error to the user. The reliable transfer delivers the segment.
- `_onAudioPacket` routes by `BleLiveAssembler.handles(value.first)` before the existing assembler, which must never see these frames.
- The relay already refuses a second segment while one upload is pending; a refused live copy simply arrives later the reliable way.

- [ ] **Step 1: Write the failing tests**
  - `a live segment completes at END`: START(7), two DATA (sequences 0, 1), END with `segmentId 0x40000007`, the right length and CRC → a `BleCompletedSegment` with `id 0x40000007`, `wakeHeard true`, the bytes joined, `recordedAt`, `durationMs`, `silenceBeforeMs`, `averageEnergy` from END.
  - `a gap drops the copy`: sequences 0 then 2 → END returns null.
  - `a wrong CRC drops the copy`, `CANCEL drops the copy`, `DATA without START is ignored`, `a new START replaces an unfinished stream`.
  - `device_protocol_test`: `buildSetLive(true)` is `[0x1D, 1]`.
  - Backend, `test_the_same_segment_uploaded_twice_is_one_segment`: post the same audio and `X-Recorded-At` twice → two 201 responses with the same id, one row, one id queued for transcription. (If this test already exists under another name, cite it in the commit instead.)
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement. Step 4: Run the app checks and the backend suite.**
- [ ] **Step 5: Commit** — `feat(app): a segment is uploaded as soon as its last word arrives`. Push.

- [ ] **USER:** `make firmware-release`, iOS build, update the pendant. Read the timing lines again: "on the server after" should fall by about the length of the old transfer. Then walk away from the phone for ten minutes while talking and come back: every segment arrives once, in order of `recorded_at`.

---

## Hardware, for the user (no code depends on it)

- **Vibration motor:** a 3 V coin motor on D4 (GPIO5) through an NPN transistor or small MOSFET with a flyback diode and a pull-down on the gate/base; then set `HAPTIC_PIN 5`.
- **An LED of its own:** LED and resistor on D3 (GPIO4), active high; then set `FEEDBACK_LED_PIN 4`. Today the only LED shares GPIO21 with the microSD and is dark whenever a card is mounted, so without this or the motor the pendant's feedback is visible only with no card.
- **Battery divider:** two 200 kΩ resistors as `config.h` already describes; then `BATTERY_DIVIDER_FITTED 1`.
- **Measure the current** (listening, recording, transferring) before any choice of another chip or microphone.

## Not in this plan

- ESP-IDF, secure boot, flash encryption, anti-rollback (decision 3).
- A phrase trained for Echo alone (decision 6). If wanted later, Task 9's export and scorer are the gate to reuse.
- Retiring "Ehi Echo" on the server: once `wake_heard` shows the new phrase in daily use.
- Streaming transcription to the server (decision 4).
- A shorter end-of-speech pause for requests: the server now answers a command that ended on a pause at once, so cutting earlier would truncate hesitant requests.
- Sending a fresh request ahead of a backlog still on the pendant: the live copy starts only when nothing is waiting.
- A cue when the answer is ready, push notifications, a lower photo resolution.
- The answer path (routing and model calls). If Milestone 0 shows the models are the largest share, that is the next plan.
