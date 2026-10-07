#pragma once

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
#define VAD_ENERGY_THRESHOLD 500       // RMS energy threshold for speech detection
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
#define PSRAM_BUFFER_SIZE (512 * 1024) // 512KB ring buffer (~64s of ADPCM)
#define SEGMENT_MAX_SIZE (120 * 1024)  // Max 120KB per segment (~15s ADPCM)

// ============================================================
// BLE Relay
// ============================================================
#define BLE_DEVICE_NAME "Echo Wearable"
#define BLE_SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define BLE_AUDIO_CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define BLE_CONTROL_CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a9"
#define BLE_PREFERRED_MTU 247
#define BLE_STATUS_ERROR_NONE 0
#define BLE_STATUS_ERROR_BUFFER_FULL 1

// ============================================================
// Conversation Segmentation
// ============================================================
#define SILENCE_TIMEOUT_MS 120000      // 2 minutes silence = new conversation

// ============================================================
// Hardware Pins
// ============================================================
#define LED_PIN 21                     // Built-in LED on XIAO ESP32-S3
#define MUTE_BUTTON_PIN 2              // GPIO for mute button (active LOW)
#define MUTE_DEBOUNCE_MS 50            // Button debounce time

static_assert(SEGMENT_MAX_SIZE < PSRAM_BUFFER_SIZE,
              "A segment must fit in the PSRAM buffer");

