#pragma once

// The firmware version the app sees (DEVICE_INFO) and `make firmware-release` publishes:
// raise it for every release, or the app will not offer the update
#define FIRMWARE_VERSION_MAJOR 0
#define FIRMWARE_VERSION_MINOR 10
#define FIRMWARE_VERSION_PATCH 4

// ============================================================
// Audio Configuration
// ============================================================
#define SAMPLE_RATE 16000        // 16 kHz
#define BITS_PER_SAMPLE 16       // 16-bit PCM
#define CHANNELS 1               // Mono
#define I2S_PORT I2S_NUM_0

// I2S pins for XIAO ESP32-S3 Sense PDM microphone
#define I2S_WS_PIN 42            // PDM CLK
#define I2S_DATA_PIN 41          // PDM Data

// Audio buffer sizes
#define PCM_BUFFER_SIZE 512      // Samples per I2S read (32ms at 16kHz)
// A segment ends at a pause (VAD_SPEECH_END_FRAMES), at the latest after this much speech:
// 25 s rather than 6, so a long sentence reaches the transcription whole
#define SEGMENT_DURATION_MS 25000

// ============================================================
// VAD (Voice Activity Detection)
// ============================================================
// Keep this intentionally low for the XIAO ESP32-S3 Sense mic. The previous
// value was tuned too aggressively and could suppress speech detection entirely
// unless the user spoke very close to the mic. The simulator uses ~500 as the
// standard default threshold; keep the firmware in the same range for easier
// calibration in real usage.
// RMS of a frame WITHOUT its constant offset (audio_level.h). Provisional: the raw RMS
// (offset included, ~1400 on the XIAO Sense mic) made 500 meaningless; calibrate with the
// serial log "[VAD] idle energy" in silence and while speaking
// The least speech must clear, on the half-second average energy: the threshold follows a
// loud background (NoiseFloor, audio_level.h) at 1.4 times its level, never under this
#define VAD_ENERGY_THRESHOLD 350
// The microphone's samples MIC_GAIN times louder (audio_level.h amplify): speech a metre
// away measured 45 to 250, under the threshold; three times that clears it, while
// silence (~30) stays well below
// The default: the app can set 1..8 (FRAME_SET_MIC_GAIN), kept across restarts
#define MIC_GAIN 3
#define VAD_SPEECH_START_FRAMES 3      // Consecutive frames above threshold to start
#define VAD_SPEECH_END_FRAMES 45       // Consecutive frames below threshold to stop (~1.4s: a pause between sentences no longer splits them)
#define VAD_FRAME_DURATION_MS 32       // Duration of one VAD frame

// Pre-buffer: keep last N frames of audio before VAD triggers
// This captures the speech onset that would otherwise be lost
#define PRE_BUFFER_FRAMES 16           // ~500ms of audio (16 × 32ms)

// The wake phrase heard on the pendant (wake_detector.h, models/wake.json): 1 once its model
// passes its gate (plan 2026-11-13, Milestone C). At 0 the model is not compiled in
#ifndef WAKE_WORD_ENABLED
#define WAKE_WORD_ENABLED 0
#endif
// When it is heard: the LED goes the other way for a moment, the motor buzzes, the app is told
#define WAKE_FLASH_MS 150
#define WAKE_HAPTIC_MS 60
// Optional parts, -1 until soldered: an LED of its own, active high (suggested D3 / GPIO4),
// which works with a microSD mounted; a vibration motor through a transistor (D4 / GPIO5)
#ifndef FEEDBACK_LED_PIN
#define FEEDBACK_LED_PIN -1
#endif
#ifndef HAPTIC_PIN
#define HAPTIC_PIN -1
#endif
// The wake phrase counts only this far into a segment (wake_window.h): the server wants the
// name among the first words
#define WAKE_WINDOW_MS 4000

// ============================================================
// Encoding
// ============================================================
// Opus at 16 kbit/s since 0.9 (opus_segment.h, opus_codec.h): 32 KB/s of PCM becomes
// ~2 KB/s; up to 0.8 it was IMA-ADPCM at 8 KB/s

// ============================================================
// PSRAM Buffer
// ============================================================
// Speech waiting for the phone: up to 6 MB (~50 minutes of speech at ~2 KB/s of Opus; only
// speech is stored, so it covers much longer away from the phone). The rest of the 8 MB PSRAM
// holds the segment being recorded, the photo slot and the camera's frame buffer.
#define PSRAM_BUFFER_SIZE (6 * 1024 * 1024)
#define PSRAM_RESERVE (768 * 1024)         // left free for the camera at each photo
#define SEGMENT_MAX_SIZE (256 * 1024)  // 25 s of Opus is ~50 KB: room to spare

// ============================================================
// BLE Relay
// ============================================================
#define BLE_DEVICE_NAME "Echo Wearable"
#define BLE_SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define BLE_AUDIO_CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define BLE_CONTROL_CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a9"
// Firmware updates: [offset u32, bytes] written with response, in order (ota_receiver.h)
#define BLE_OTA_CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26aa"
#define BLE_PREFERRED_MTU 247
#define BLE_STATUS_ERROR_NONE 0
#define BLE_STATUS_ERROR_BUFFER_FULL 1

// ============================================================
// Conversation Segmentation
// ============================================================
#define SILENCE_TIMEOUT_MS 120000      // 2 minutes silence = new conversation

// ============================================================
// Camera (XIAO ESP32-S3 Sense, OV3660 or OV2640 on the B2B connector)
// ============================================================
// Taken only on TAKE_PHOTO from the app; the JPEG stays in RAM until uploaded.
// FRAMESIZE_UXGA (1600x1200, 24/10: XGA was too soft to read small text) is ~150-350 KB,
// ~6-10 s over BLE; the camera's frame buffer (~400 KB) fits in PSRAM_RESERVE.
// FRAMESIZE_XGA (1024x768) halves the transfer.
#define PHOTO_FRAME_SIZE FRAMESIZE_UXGA
#define PHOTO_JPEG_QUALITY 12          // 0-63, lower is better
#define PHOTO_MAX_BYTES (768 * 1024)   // PSRAM slot for one JPEG (the server takes 1 MB)
#define PHOTO_WARMUP_FRAMES 10         // dropped while exposure and white balance settle (3 came dark)
#define PHOTO_FLASH_MS 300             // LED on while a photo is taken

#define CAM_PIN_PWDN -1
#define CAM_PIN_RESET -1
#define CAM_PIN_XCLK 10
#define CAM_PIN_SIOD 40
#define CAM_PIN_SIOC 39
#define CAM_PIN_D7 48
#define CAM_PIN_D6 11
#define CAM_PIN_D5 12
#define CAM_PIN_D4 14
#define CAM_PIN_D3 16
#define CAM_PIN_D2 18
#define CAM_PIN_D1 17
#define CAM_PIN_D0 15
#define CAM_PIN_VSYNC 38
#define CAM_PIN_HREF 47
#define CAM_PIN_PCLK 13

// ============================================================
// Battery (1:2 divider: 200 kOhm BAT+ -> A0 -> 200 kOhm GND)
// ============================================================
// Set to 1 once the divider is soldered: an unconnected A0 floats and could read a
// plausible but meaningless voltage. Until then the app shows the battery as unknown.
#define BATTERY_DIVIDER_FITTED 0
#define BATTERY_ADC_PIN 1                  // A0 / GPIO1 (ADC1, usable with BLE)
#define BATTERY_DIVIDER_RATIO 2.0f         // Vbat / Vpin
#define BATTERY_SAMPLES 16                 // averaged per reading
#define BATTERY_SAMPLE_INTERVAL_MS 30000

// ============================================================
// Firmware updates over BLE
// ============================================================
#define OTA_MIN_BATTERY_PERCENT 20                  // when the battery level is known
#define OTA_IDLE_TIMEOUT_MS 30000                   // no chunk for this long: transfer dropped
#define OTA_RESTART_DELAY_MS 500                    // after DONE is sent, before restarting
#define OTA_CONFIRM_TIMEOUT_MS (5UL * 60UL * 1000UL)  // new firmware without the app: roll back

// ============================================================
// Hardware Pins
// ============================================================
#define LED_PIN 21                     // Built-in LED on XIAO ESP32-S3

// microSD on the Sense board (FAT32, up to 32 GB): SPI, CS shared with the LED
#define SD_CS_PIN 21
#define SD_SCK_PIN 7
#define SD_MISO_PIN 8
#define SD_MOSI_PIN 9
#define SD_SPI_HZ 20000000
// Speech waiting on the card: log files of this size (sd_storage.h, segment_log.h)
#define SD_LOG_FILE_BYTES (4UL * 1024 * 1024)
// The card's speech, encrypted (0.6.0 kept it in clear in /echo/q)
#define SD_SEALED_FOLDER "/echo/s"
// The button, between D1 (GPIO2) and GND (internal pull-up): a short press takes a photo,
// a long press (released after 1.5 s) mutes or resumes listening, a 5 s hold turns Echo
// off. Off, a 1.5 s hold turns it on (GPIO2 is an RTC pin: it can wake the chip)
#define BUTTON_PIN 2
#define BUTTON_DEBOUNCE_MS 50
#define BUTTON_LONG_PRESS_MS 1500
#define BUTTON_POWER_OFF_MS 5000
#define BUTTON_WAKE_HOLD_MS 1500

// 80 MHz was not enough: Opus, BLE and the card left the loop behind the microphone, whose
// DMA (256 ms) overflowed, and every segment lost about a fifth of its audio (measured on the
// server: 25 s declared, ~19.5 s decoded), so speech came out garbled. 240 MHz only ran hotter
// Overridable to try another (PLATFORMIO_BUILD_FLAGS="-DCPU_FREQ_MHZ=240" pio run -t upload)
#ifndef CPU_FREQ_MHZ
#define CPU_FREQ_MHZ 160
#endif
#define FATAL_RESTART_DELAY_MS 5000    // a failed start is tried again after this

static_assert(SEGMENT_MAX_SIZE < PSRAM_BUFFER_SIZE,
              "A segment must fit in the PSRAM buffer");

