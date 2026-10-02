/**
 * Echo — Second Brain AI Wearable
 * Firmware for Seeed Studio XIAO ESP32-S3 Sense
 *
 * Main loop:
 * 1. Capture PCM audio from PDM microphone (I2S)
 * 2. Run VAD to detect speech
 * 3. Encode speech to ADPCM
 * 4. Store every completed segment in PSRAM
 * 5. Relay the oldest segment over BLE
 * 6. Keep capture active while BLE advances incrementally
 */

#include "config.h"
#include "audio_capture.h"
#include "vad.h"
#include "adpcm_encoder.h"
#include "ble_transport.h"
#include "psram_buffer.h"
#include "indicators.h"
#include "device_preferences.h"
#include "mute_state.h"

// ============================================================
// Global instances
// ============================================================
AudioCapture audio;
VAD vad;
ADPCMEncoder encoder;
BleTransport bleTransport;
PSRAMBuffer buffer;
Indicators indicators;
DevicePreferences devicePreferences;
MuteState muteState(
    [](bool& muted) { return devicePreferences.loadMuted(muted); },
    [](bool muted) { return devicePreferences.saveMuted(muted); });

// ============================================================
// State
// ============================================================
enum DeviceState {
    STATE_IDLE,         // Listening for speech
    STATE_RECORDING,    // Capturing and encoding speech
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
uint32_t nextSegmentId = 1;
uint32_t segmentCrcAccumulator = EchoBleProtocol::CRC32_INITIAL_VALUE;

void discardInProgressCapture();

void handleMuteCommand(bool muted, void*) {
    const bool changed = muteState.isMuted() != muted;
    const bool persisted = muteState.setMuted(muted);

    if (changed) discardInProgressCapture();

    indicators.setMuted(muteState.isMuted());
    bleTransport.setMuted(muteState.isMuted());

    if (!persisted) {
        Serial.println("[Privacy] Failed to persist mute state");
    }
    Serial.printf("[Privacy] Mute: %s\n", muteState.isMuted() ? "ON" : "OFF");
}

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

    bleTransport.setMuteCommandCallback(handleMuteCommand, nullptr);

    if (!devicePreferences.begin()) {
        Serial.println("[Privacy] Preferences init failed; defaulting to listening");
    }
    if (!muteState.begin()) {
        Serial.println("[Privacy] Mute state load failed; defaulting to listening");
    }
    indicators.setMuted(muteState.isMuted());
    bleTransport.setMuted(muteState.isMuted());

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

    if (!bleTransport.begin()) {
        Serial.println("[FATAL] BLE transport init failed");
        while (true) { delay(1000); }
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
    bleTransport.update(buffer);



    if (muteState.isMuted()) {
        if (state != STATE_IDLE || segmentPos != 0 || preBufferCount != 0) {
            discardInProgressCapture();
        }

        delay(50);
        return;
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
                segmentCrcAccumulator = EchoBleProtocol::CRC32_INITIAL_VALUE;
                encoder.reset();
                indicators.setRecording(true);

                // Encode the pre-buffer first (captures speech onset)
                const uint8_t replayFrames = preBufferCount - 1;
                uint8_t readIdx = (preBufferWriteIdx - preBufferCount + PRE_BUFFER_FRAMES) % PRE_BUFFER_FRAMES;
                for (uint8_t i = 0; i < replayFrames; i++) {
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

    }
}

// ============================================================
// Helpers
// ============================================================

void discardInProgressCapture() {
    indicators.setRecording(false);
    state = STATE_IDLE;
    segmentPos = 0;
    energySum = 0;
    energyFrameCount = 0;
    segmentCrcAccumulator = EchoBleProtocol::CRC32_INITIAL_VALUE;
    encoder.reset();
    vad.reset();
    preBufferCount = 0;
    preBufferWriteIdx = 0;
}

void encodeFrame(const int16_t* samples, size_t count) {
    size_t adpcmBytes = encoder.encode(samples, count, adpcmFrame);
    if (segmentPos + adpcmBytes <= SEGMENT_MAX_SIZE) {
        memcpy(segmentBuffer + segmentPos, adpcmFrame, adpcmBytes);
        segmentPos += adpcmBytes;
        segmentCrcAccumulator = EchoBleProtocol::crc32Update(
            segmentCrcAccumulator, adpcmFrame, adpcmBytes);
    }
}

void finalizeSegment() {

    if (segmentPos == 0) {
        Serial.println("[Main] Empty segment, resetting");

        indicators.setRecording(false);

        // Reset VAD and buffers before returning to listening
        vad.reset();

        preBufferCount = 0;
        preBufferWriteIdx = 0;

        state = STATE_IDLE;
        return;
    }


    indicators.setRecording(false);


    uint32_t durationMs = millis() - segmentStartMs;

    Serial.printf(
        "[Main] Segment ready: %u bytes, %ums\n",
        (unsigned)segmentPos,
        durationMs
    );


    const uint16_t avgEnergy =
        energyFrameCount > 0
        ? static_cast<uint16_t>(energySum / energyFrameCount)
        : 0;


    const uint32_t segmentId = nextSegmentId++;
    const uint32_t segmentCrc = EchoBleProtocol::crc32Finalize(segmentCrcAccumulator);


    indicators.setBlinking(true);


    const auto storeNewest = [&]() {
        return buffer.store(
            segmentId,
            segmentBuffer,
            segmentPos,
            durationMs,
            lastSilenceDurationMs,
            segmentStartMs,
            avgEnergy,
            segmentCrc
        );
    };

    bool stored = storeNewest();
    while (!stored) {
        BufferedSegment oldest = {};
        const uint8_t* oldestData = nullptr;
        if (!buffer.peek(oldest, &oldestData)) break;

        bleTransport.cancelActiveForOverflow(oldest.segmentId);
        const uint32_t droppedSegmentId = buffer.dropOldest();
        if (droppedSegmentId == 0) break;

        bleTransport.reportBufferOverflow();
        Serial.printf(
            "[Main] Dropped segment %u for overflow (dropped total: %u)\n",
            droppedSegmentId,
            buffer.droppedSegmentCount()
        );
        stored = storeNewest();
    }

    if (!stored) {

        Serial.println(
            "[Main] PSRAM buffer empty but newest segment still could not be stored. Segment lost."
        );

    } else {

        Serial.printf(
            "[Main] Stored segment %u: %u bytes (buffered: %u)\n",
            segmentId,
            (unsigned)segmentPos,
            (unsigned)buffer.count()
        );


        if (!bleTransport.isConnected()) {

            Serial.println(
                "[Main] No BLE connection — waiting"
            );

        } else {

            Serial.println(
                "[Main] BLE connected — sending"
            );
        }


        bleTransport.requestBufferStatus();
    }


    indicators.setBlinking(false);


    // ====================================================
    // IMPORTANT:
    // Prepare system for next recording
    // ====================================================

    segmentPos = 0;
    energySum = 0;
    energyFrameCount = 0;
    segmentCrcAccumulator = EchoBleProtocol::CRC32_INITIAL_VALUE;

    vad.reset();

    preBufferCount = 0;
    preBufferWriteIdx = 0;


    state = STATE_IDLE;


    Serial.println(
        "[Main] Ready for next speech segment"
    );
}