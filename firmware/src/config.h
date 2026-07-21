#pragma once

// ============================================================
// Wi-Fi Configuration
// ============================================================
// Credentials are in secrets.h (not tracked by git)
#include "secrets.h"

// If secrets.h doesn't exist, uncomment and fill these:
// #define WIFI_SSID "YOUR_WIFI_SSID"
// #define WIFI_PASSWORD "YOUR_WIFI_PASSWORD"
// #define API_KEY "my-secret-key"

// ============================================================
// Backend Server
// ============================================================
// For local dev: use your PC's IP (e.g. "192.168.1.100", port 8000)
// For production: use Cloudflare Tunnel domain
#define SERVER_HOST "echo.man.ovh"
#define SERVER_PORT 443
#define SERVER_ENDPOINT "/api/segments"

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
#define SEGMENT_DURATION_MS 5000 // Send segment every 5 seconds of speech

// ============================================================
// VAD (Voice Activity Detection)
// ============================================================
#define VAD_ENERGY_THRESHOLD 500       // Minimum RMS energy to consider as speech
#define VAD_SPEECH_START_FRAMES 3      // Consecutive frames above threshold to start
#define VAD_SPEECH_END_FRAMES 30       // Consecutive frames below threshold to stop (~1s)
#define VAD_FRAME_DURATION_MS 32       // Duration of one VAD frame

// ============================================================
// ADPCM Encoding
// ============================================================
// IMA-ADPCM compresses 16-bit PCM to 4-bit (4:1 ratio)
// At 16kHz mono: 32KB/s PCM → 8KB/s ADPCM

// ============================================================
// PSRAM Buffer
// ============================================================
#define PSRAM_BUFFER_SIZE (256 * 1024) // 256KB ring buffer (~32s of ADPCM)
#define SEGMENT_MAX_SIZE (40 * 1024)   // Max 40KB per segment (~5s ADPCM)

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

// ============================================================
// HTTP Client
// ============================================================
#define HTTP_TIMEOUT_MS 10000          // 10 second timeout for HTTP POST
#define HTTP_MAX_RETRIES 3             // Max retries on failure
#define HTTP_RETRY_DELAY_MS 1000       // Delay between retries

// ============================================================
// System
// ============================================================
#define WIFI_CONNECT_TIMEOUT_MS 10000  // WiFi connection timeout
#define WIFI_RECONNECT_INTERVAL_MS 5000 // Try reconnect every 5s
