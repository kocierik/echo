#pragma once

// The firmware version the app sees (DEVICE_INFO) and `make firmware-release` publishes:
// raise it for every release, or the app will not offer the update
#define FIRMWARE_VERSION_MAJOR 0
#define FIRMWARE_VERSION_MINOR 5
#define FIRMWARE_VERSION_PATCH 1

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
#define SEGMENT_DURATION_MS 6000  // Send segment every 6 seconds of speech max

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
#define VAD_ENERGY_THRESHOLD 250
#define VAD_SPEECH_START_FRAMES 3      // Consecutive frames above threshold to start
#define VAD_SPEECH_END_FRAMES 25       // Consecutive frames below threshold to stop (~800ms)
#define VAD_FRAME_DURATION_MS 32       // Duration of one VAD frame

// Pre-buffer: keep last N frames of audio before VAD triggers
// This captures the speech onset that would otherwise be lost
#define PRE_BUFFER_FRAMES 16           // ~500ms of audio (16 × 32ms)

// ============================================================
// ADPCM Encoding
// ============================================================
// IMA-ADPCM compresses 16-bit PCM to 4-bit (4:1 ratio)
// At 16kHz mono: 32KB/s PCM → 8KB/s ADPCM

// ============================================================
// PSRAM Buffer
// ============================================================
// Speech waiting for the phone: up to 6 MB (~13 minutes of speech at 8 KB/s; only speech
// is stored, so it covers much longer away from the phone). The rest of the 8 MB PSRAM
// holds the segment being recorded, the photo slot and the camera's frame buffer.
#define PSRAM_BUFFER_SIZE (6 * 1024 * 1024)
#define PSRAM_RESERVE (768 * 1024)         // left free for the camera at each photo
#define SEGMENT_MAX_SIZE (120 * 1024)  // Max 120KB per segment (~15s ADPCM)

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
// FRAMESIZE_XGA (1024x768) keeps text readable at ~60-120 KB (~3-5 s over BLE);
// FRAMESIZE_SVGA (800x600) halves the transfer.
#define PHOTO_FRAME_SIZE FRAMESIZE_XGA
#define PHOTO_JPEG_QUALITY 12          // 0-63, lower is better
#define PHOTO_MAX_BYTES (512 * 1024)   // PSRAM slot for one JPEG
#define PHOTO_WARMUP_FRAMES 3          // dropped while auto-exposure settles
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
// The button, between D1 (GPIO2) and GND (internal pull-up): a short press takes a photo,
// a long press mutes or resumes listening
#define BUTTON_PIN 2
#define BUTTON_DEBOUNCE_MS 50
#define BUTTON_LONG_PRESS_MS 1500

static_assert(SEGMENT_MAX_SIZE < PSRAM_BUFFER_SIZE,
              "A segment must fit in the PSRAM buffer");

