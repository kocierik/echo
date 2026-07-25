/**
 * Echo — Second Brain AI Wearable
 * Firmware for Seeed Studio XIAO ESP32-S3 Sense
 *
 * Main loop:
 * 1. Capture PCM audio from PDM microphone (I2S)
 * 2. Run VAD to detect speech
 * 3. Encode speech to ADPCM
 * 4. Send via HTTP POST when segment is complete
 * 5. Buffer in PSRAM when WiFi is unavailable
 * 6. LED and mute button for user feedback
 */

#include <WiFi.h>
#include "config.h"
#include "audio_capture.h"
#include "vad.h"
#include "adpcm_encoder.h"
#include "http_sender.h"
#include "psram_buffer.h"
#include "indicators.h"
#include "time_sync.h"

// ============================================================
// Global instances
// ============================================================
AudioCapture audio;
VAD vad;
ADPCMEncoder encoder;
HttpSender http;
PSRAMBuffer buffer;
Indicators indicators;
TimeSync timeSync;

// ============================================================
// State
// ============================================================
enum DeviceState {
    STATE_IDLE,         // Listening for speech
    STATE_RECORDING,    // Capturing and encoding speech
    STATE_SENDING,      // Sending segment to backend
};

DeviceState state = STATE_IDLE;

// Buffers
int16_t pcmBuffer[PCM_BUFFER_SIZE];
uint8_t adpcmFrame[PCM_BUFFER_SIZE / 2];  // ADPCM is 4:1

// Pre-buffer: circular buffer of recent audio frames (captures speech onset)
int16_t preBuffer[PRE_BUFFER_FRAMES][PCM_BUFFER_SIZE];
uint8_t preBufferWriteIdx = 0;
uint8_t preBufferCount = 0;  // how many frames are stored (up to PRE_BUFFER_FRAMES)

// Segment accumulation buffer (on PSRAM)
uint8_t* segmentBuffer = nullptr;
size_t segmentPos = 0;
uint32_t segmentStartMs = 0;
uint32_t lastSilenceDurationMs = 0;
uint32_t energySum = 0;
uint16_t energyFrameCount = 0;
char segmentTimestamp[30];

// WiFi reconnection
uint32_t lastWifiCheckMs = 0;

// ============================================================
// Setup
// ============================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n=== Echo — Second Brain Wearable ===");

    // Initialize indicators first (for visual feedback during boot)
    indicators.begin();
    indicators.setBlinking(true);

    // Initialize PSRAM buffer
    if (!buffer.begin()) {
        Serial.println("[FATAL] PSRAM buffer init failed");
        while (true) { delay(1000); }
    }

    // Allocate segment accumulation buffer on PSRAM
    segmentBuffer = (uint8_t*)ps_malloc(SEGMENT_MAX_SIZE);
    if (!segmentBuffer) {
        Serial.println("[FATAL] Failed to allocate segment buffer");
        while (true) { delay(1000); }
    }

    // Connect to WiFi
    connectWiFi();

    // Sync time via NTP
    if (http.isConnected()) {
        timeSync.begin();
    }

    // Initialize audio capture
    if (!audio.begin()) {
        Serial.println("[FATAL] Audio capture init failed");
        while (true) { delay(1000); }
    }

    // Reset encoder and VAD
    encoder.reset();
    vad.reset();

    indicators.setBlinking(false);
    Serial.println("[OK] System ready — listening for speech\n");
}

// ============================================================
// Main Loop
// ============================================================
void loop() {
    indicators.update();

    // Check mute state
    if (indicators.isMuted()) {
        // If we were recording, finalize the segment
        if (state == STATE_RECORDING) {
            finalizeSegment();
        }
        delay(50);
        return;
    }

    // WiFi reconnection check
    if (!http.isConnected() && (millis() - lastWifiCheckMs > WIFI_RECONNECT_INTERVAL_MS)) {
        lastWifiCheckMs = millis();
        reconnectWiFi();
    }

    // Periodic NTP resync
    timeSync.resync();

    // Flush buffered segments when WiFi is back
    if (http.isConnected() && !buffer.isEmpty()) {
        flushBuffer();
    }

    // Read audio frame from microphone
    int samplesRead = audio.readSamples(pcmBuffer, PCM_BUFFER_SIZE);
    if (samplesRead <= 0) return;

    // Run VAD on the frame
    bool isSpeech = vad.process(pcmBuffer, samplesRead);

    switch (state) {
        case STATE_IDLE:
            // Always store in pre-buffer (circular, overwrites oldest)
            memcpy(preBuffer[preBufferWriteIdx], pcmBuffer, PCM_BUFFER_SIZE * sizeof(int16_t));
            preBufferWriteIdx = (preBufferWriteIdx + 1) % PRE_BUFFER_FRAMES;
            if (preBufferCount < PRE_BUFFER_FRAMES) preBufferCount++;

            if (vad.speechStarted()) {
                // Start recording a new segment
                state = STATE_RECORDING;
                segmentPos = 0;
                segmentStartMs = millis() - (preBufferCount * VAD_FRAME_DURATION_MS); // adjust for pre-buffer
                lastSilenceDurationMs = vad.getLastSilenceDurationMs();
                energySum = 0;
                energyFrameCount = 0;
                timeSync.getTimestamp(segmentTimestamp, sizeof(segmentTimestamp));
                encoder.reset();
                indicators.setRecording(true);

                // Encode the pre-buffer first (captures speech onset)
                uint8_t readIdx = (preBufferWriteIdx - preBufferCount + PRE_BUFFER_FRAMES) % PRE_BUFFER_FRAMES;
                for (uint8_t i = 0; i < preBufferCount; i++) {
                    encodeFrame(preBuffer[readIdx], PCM_BUFFER_SIZE);
                    readIdx = (readIdx + 1) % PRE_BUFFER_FRAMES;
                }
                preBufferCount = 0;

                // Encode this current frame too
                encodeFrame(pcmBuffer, samplesRead);
                energySum += vad.getEnergy();
                energyFrameCount++;
            }
            break;

        case STATE_RECORDING:
            if (isSpeech || !vad.speechEnded()) {
                // Continue recording
                encodeFrame(pcmBuffer, samplesRead);
                energySum += vad.getEnergy();
                energyFrameCount++;

                // Check if segment is full (max duration reached)
                uint32_t elapsed = millis() - segmentStartMs;
                if (elapsed >= SEGMENT_DURATION_MS || segmentPos >= SEGMENT_MAX_SIZE - PCM_BUFFER_SIZE) {
                    finalizeSegment();
                }
            } else if (vad.speechEnded()) {
                // Speech ended — encode the trailing silence too (for natural audio)
                encodeFrame(pcmBuffer, samplesRead);
                finalizeSegment();
            }
            break;

        case STATE_SENDING:
            // Should not stay in this state in the main loop
            state = STATE_IDLE;
            break;
    }
}

// ============================================================
// Helpers
// ============================================================

void encodeFrame(const int16_t* samples, size_t count) {
    size_t adpcmBytes = encoder.encode(samples, count, adpcmFrame);
    if (segmentPos + adpcmBytes <= SEGMENT_MAX_SIZE) {
        memcpy(segmentBuffer + segmentPos, adpcmFrame, adpcmBytes);
        segmentPos += adpcmBytes;
    }
}

void finalizeSegment() {
    if (segmentPos == 0) {
        state = STATE_IDLE;
        indicators.setRecording(false);
        return;
    }

    state = STATE_SENDING;
    indicators.setRecording(false);

    uint32_t durationMs = millis() - segmentStartMs;
    Serial.printf("[Main] Segment ready: %u bytes, %ums\n", segmentPos, durationMs);

    SegmentMetadata meta;
    meta.durationMs = durationMs;
    meta.silenceBeforeMs = lastSilenceDurationMs;
    meta.avgEnergy = (energyFrameCount > 0) ? (uint16_t)(energySum / energyFrameCount) : 0;
    strncpy(meta.recordedAt, segmentTimestamp, sizeof(meta.recordedAt));

    // Try to send directly
    if (http.isConnected()) {
        if (http.sendSegment(segmentBuffer, segmentPos, meta)) {
            state = STATE_IDLE;
            return;
        }
    }

    // WiFi unavailable or send failed — buffer in PSRAM
    Serial.println("[Main] Buffering segment in PSRAM");
    indicators.setBlinking(true);

    if (!buffer.store(segmentBuffer, segmentPos, durationMs, lastSilenceDurationMs, segmentTimestamp)) {
        Serial.println("[Main] PSRAM buffer full! Segment lost.");
    }

    indicators.setBlinking(false);
    state = STATE_IDLE;
}

void flushBuffer() {
    Serial.printf("[Main] Flushing %u buffered segments...\n", buffer.count());
    indicators.setBlinking(true);

    while (!buffer.isEmpty() && http.isConnected()) {
        BufferedSegment header;
        const uint8_t* data;

        if (!buffer.peek(header, &data)) break;

        SegmentMetadata meta;
        meta.durationMs = header.durationMs;
        meta.silenceBeforeMs = header.silenceBeforeMs;
        strncpy(meta.recordedAt, header.recordedAt, sizeof(meta.recordedAt));

        if (http.sendSegment(data, header.dataLength, meta)) {
            buffer.dequeue();
        } else {
            // WiFi probably dropped, stop flushing
            break;
        }

        // Small delay to avoid overwhelming the backend
        delay(100);
    }

    indicators.setBlinking(false);
}

void connectWiFi() {
    Serial.printf("[WiFi] Connecting to %s...\n", WIFI_SSID);
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    uint32_t start = millis();
    while (WiFi.status() != WL_CONNECTED && (millis() - start < WIFI_CONNECT_TIMEOUT_MS)) {
        delay(250);
        Serial.print(".");
    }

    if (WiFi.status() == WL_CONNECTED) {
        Serial.printf("\n[WiFi] Connected! IP: %s\n", WiFi.localIP().toString().c_str());
    } else {
        Serial.println("\n[WiFi] Connection failed — will retry later");
    }
}

void reconnectWiFi() {
    if (WiFi.status() == WL_CONNECTED) return;
    Serial.println("[WiFi] Attempting reconnection...");
    WiFi.disconnect();
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    // Wait briefly for connection
    uint32_t start = millis();
    while (WiFi.status() != WL_CONNECTED && (millis() - start < 3000)) {
        delay(100);
    }

    if (WiFi.status() == WL_CONNECTED) {
        Serial.printf("[WiFi] Reconnected! IP: %s\n", WiFi.localIP().toString().c_str());
        if (!timeSync.isSynced()) {
            timeSync.begin();
        }
    }
}
