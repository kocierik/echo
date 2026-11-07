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
 * 7. On TAKE_PHOTO from the app, take a photo (camera task, core 0) and relay it
 *    before the audio; it stays in RAM only until the app confirms the upload
 * 8. On OTA_BEGIN, pause capture and write the new firmware to the other app slot;
 *    after the restart it is kept only once the app talks to it (ota_health.h)
 */

#include <esp_ota_ops.h>

#include "config.h"
#include "audio_capture.h"
#include "vad.h"
#include "adpcm_encoder.h"
#include "ble_transport.h"
#include "psram_buffer.h"
#include "sd_cipher.h"
#include "sd_storage.h"
#include "segment_log.h"
#include "indicators.h"
#include "device_preferences.h"
#include "mute_state.h"
#include "photo_slot.h"
#include "camera_capture.h"
#include "battery_monitor.h"
#include "button_gesture.h"
#include "ota_health.h"

// ============================================================
// Global instances
// ============================================================
AudioCapture audio;
VAD vad;
ADPCMEncoder encoder;
BleTransport bleTransport;
PSRAMBuffer psram;
// The segments for the phone: PSRAM, and the microSD when one is mounted
SegmentQueue buffer(psram);
SdStorage sdCard;
// The card's speech, encrypted with this device's key; 0.6.0's, in clear, moves into it
AesCtrCipher sdCipher;
SegmentLog sdLog(sdCard, SD_LOG_FILE_BYTES, SD_SEALED_FOLDER, &sdCipher);
SegmentLog sdLegacyLog(sdCard, SD_LOG_FILE_BYTES);
Indicators indicators;
DevicePreferences devicePreferences;
PhotoSlot photoSlot;
CameraCapture camera;
BatteryMonitor battery;
ButtonGesture button(BUTTON_DEBOUNCE_MS, BUTTON_LONG_PRESS_MS);
OtaHealthCheck otaHealth(OTA_CONFIRM_TIMEOUT_MS);
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
void dropPhotoForPrivacy();

// The Arduino core would accept a new firmware as soon as it boots; Echo waits for the app.
// The core defines the weak default in C (esp32-hal-misc.c): C linkage, or it is ignored
extern "C" bool verifyRollbackLater() { return true; }

/** Cannot run: a firmware on trial goes back to the previous one, otherwise wait. */
/** A segment moves from PSRAM to the card: the transport stops sending it from PSRAM
 *  (it is sent again later, from the card). */
void moveToCard(uint32_t segmentId) {
    bleTransport.cancelActiveForOverflow(segmentId);
}

void fatal(const char* message) {
    Serial.println(message);
    if (otaHealth.onTrial()) {
        Serial.println("[OTA] new firmware failed to start: rolling back");
        esp_ota_mark_app_invalid_rollback_and_reboot();
    }
    while (true) { delay(1000); }
}

void handleTakePhoto(void*) {
    if (bleTransport.otaInProgress()) {
        bleTransport.reportPhotoFailed(EchoBleProtocol::PHOTO_FAILED_BUSY);
    } else if (muteState.isMuted()) {
        bleTransport.reportPhotoFailed(EchoBleProtocol::PHOTO_FAILED_MUTED);
    } else if (!camera.isAvailable()) {
        bleTransport.reportPhotoFailed(EchoBleProtocol::PHOTO_FAILED_NO_CAMERA);
    } else if (!photoSlot.request()) {
        bleTransport.reportPhotoFailed(EchoBleProtocol::PHOTO_FAILED_BUSY);
    } else {
        indicators.flash(PHOTO_FLASH_MS);  // visible to the people around
        camera.trigger();
    }
}

void handleMuteCommand(bool muted, void*) {
    const bool changed = muteState.isMuted() != muted;
    const bool persisted = muteState.setMuted(muted);

    if (changed) discardInProgressCapture();
    if (muteState.isMuted()) dropPhotoForPrivacy();

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
    Serial.printf("\n=== Echo — Second Brain Wearable %d.%d.%d ===\n",
                  FIRMWARE_VERSION_MAJOR, FIRMWARE_VERSION_MINOR, FIRMWARE_VERSION_PATCH);

    esp_ota_img_states_t otaState;
    const bool onTrial =
        esp_ota_get_state_partition(esp_ota_get_running_partition(), &otaState) == ESP_OK &&
        otaState == ESP_OTA_IMG_PENDING_VERIFY;
    otaHealth.begin(onTrial, millis());
    if (onTrial) Serial.println("[OTA] new firmware: waiting for the app to confirm it");

    // Initialize indicators first (for visual feedback during boot)
    indicators.begin();
    pinMode(BUTTON_PIN, INPUT_PULLUP);
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

    // Allocate segment accumulation buffer on PSRAM
    segmentBuffer = (uint8_t*)ps_malloc(SEGMENT_MAX_SIZE);
    if (!segmentBuffer) fatal("[FATAL] Failed to allocate segment buffer");

    // The JPEG slot before the speech buffer, which takes most of what is left
    uint8_t* photoBuffer = (uint8_t*)ps_malloc(PHOTO_MAX_BYTES);
    if (photoBuffer != nullptr) photoSlot.attach(photoBuffer, PHOTO_MAX_BYTES);

    // microSD (optional): speech that does not fit in PSRAM waits there instead of being
    // dropped. Its chip select is the LED's pin: with a card the LED stays dark
    uint8_t* sdStaging = nullptr;
    if (sdCard.begin()) {
        indicators.release();
        sdStaging = (uint8_t*)ps_malloc(SEGMENT_MAX_SIZE);
    }

    // Initialize PSRAM buffer
    if (!psram.begin()) fatal("[FATAL] PSRAM buffer init failed");

    // Camera (optional): no camera, no photos
    const bool cameraAvailable = camera.begin(photoSlot);
    Serial.printf("[Camera] %s\n", cameraAvailable ? "ready" : "not available");
    bleTransport.setPhotoSlot(&photoSlot, cameraAvailable);

    battery.begin();
    bleTransport.setBatteryPercent(battery.percent());
    bleTransport.setTakePhotoCallback(handleTakePhoto, nullptr);

    if (!bleTransport.begin()) fatal("[FATAL] BLE transport init failed");

    // The card, once the radio is on (the key, made the first time, needs true random
    // numbers). Without its key nothing goes on the card: speech is never written in clear
    if (sdStaging != nullptr && sdCipher.begin() && sdLog.begin()) {
        if (sdLegacyLog.begin()) {
            const uint32_t sealed =
                SegmentLog::moveAll(sdLegacyLog, sdLog, sdStaging, SEGMENT_MAX_SIZE);
            if (sealed > 0) Serial.printf("[SD] %lu segments from 0.6.0 encrypted\n",
                                          static_cast<unsigned long>(sealed));
        }
        buffer.attachCard(&sdLog, sdStaging, SEGMENT_MAX_SIZE, moveToCard);
        Serial.printf("[SD] speech overflow on the card, encrypted (%llu KB waiting)\n",
                      static_cast<unsigned long long>(sdLog.pendingBytes() / 1024));
    } else if (sdStaging != nullptr) {
        Serial.println("[SD] card not used: its key could not be loaded");
    }

    // Initialize audio capture
    if (!audio.begin()) fatal("[FATAL] Audio capture init failed");

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

    switch (otaHealth.update(bleTransport.appTalking(), millis())) {
        case OtaHealthCheck::Decision::KEEP:
            esp_ota_mark_app_valid_cancel_rollback();
            Serial.println("[OTA] new firmware confirmed by the app");
            break;
        case OtaHealthCheck::Decision::ROLL_BACK:
            Serial.println("[OTA] the app never came back: rolling back");
            esp_ota_mark_app_invalid_rollback_and_reboot();
            break;
        case OtaHealthCheck::Decision::NONE:
            break;
    }
    if (bleTransport.otaRestartDue(millis())) {
        Serial.println("[OTA] restarting into the new firmware");
        Serial.flush();
        ESP.restart();
    }

    uint8_t photoFailure = 0;
    if (photoSlot.takeFailure(photoFailure)) bleTransport.reportPhotoFailed(photoFailure);
    if (battery.update()) bleTransport.setBatteryPercent(battery.percent());

    // The button works muted too: a long press is also how listening resumes
    switch (button.update(digitalRead(BUTTON_PIN) == LOW, millis())) {
        case ButtonGesture::SHORT_PRESS:
            Serial.println("[Button] short press: photo");
            handleTakePhoto(nullptr);
            break;
        case ButtonGesture::LONG_PRESS:
            Serial.println("[Button] long press: mute toggle");
            handleMuteCommand(!muteState.isMuted(), nullptr);
            break;
        case ButtonGesture::NONE:
            break;
    }

    // While a new firmware arrives the microphone pauses (the mute setting is unchanged)
    if (bleTransport.otaInProgress()) {
        if (state != STATE_IDLE || segmentPos != 0 || preBufferCount != 0) {
            discardInProgressCapture();
        }
        delay(5);
        return;
    }

    if (muteState.isMuted()) {
        if (state != STATE_IDLE || segmentPos != 0 || preBufferCount != 0) {
            discardInProgressCapture();
        }
        // A photo that finished after muting is dropped too
        if (photoSlot.isReady()) dropPhotoForPrivacy();

        delay(50);
        return;
    }

    // Read audio frame from microphone
    int samplesRead = audio.readSamples(pcmBuffer, PCM_BUFFER_SIZE);
    if (samplesRead <= 0) return;
    amplify(pcmBuffer, samplesRead, MIC_GAIN);

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

void dropPhotoForPrivacy() {
    bleTransport.cancelPhoto();
    if (photoSlot.discard()) {
        bleTransport.reportPhotoFailed(EchoBleProtocol::PHOTO_FAILED_MUTED);
        Serial.println("[Privacy] Photo dropped: muted");
    }
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
    indicators.setRecording(false);

    if (segmentPos == 0) {
        Serial.println("[Main] Empty segment, resetting");
        // Reset VAD and buffers before returning to listening
        vad.reset();
        preBufferCount = 0;
        preBufferWriteIdx = 0;
        state = STATE_IDLE;
        return;
    }

    const uint32_t durationMs = millis() - segmentStartMs;
    Serial.printf("[Main] Segment ready: %u bytes, %ums\n", (unsigned)segmentPos, durationMs);

    const uint16_t avgEnergy =
        energyFrameCount > 0 ? static_cast<uint16_t>(energySum / energyFrameCount) : 0;
    const uint32_t segmentId = nextSegmentId++;
    const uint32_t segmentCrc = EchoBleProtocol::crc32Finalize(segmentCrcAccumulator);

    indicators.setBlinking(true);

    const auto storeNewest = [&]() {
        return buffer.store(segmentId, segmentBuffer, segmentPos, durationMs,
                            lastSilenceDurationMs, segmentStartMs, avgEnergy, segmentCrc);
    };

    // A full buffer drops its oldest segments to make room for the newest
    bool stored = storeNewest();
    while (!stored) {
        BufferedSegment oldest = {};
        const uint8_t* oldestData = nullptr;
        if (!buffer.peek(oldest, &oldestData)) break;

        bleTransport.cancelActiveForOverflow(oldest.segmentId);
        const uint32_t droppedSegmentId = buffer.dropOldest();
        if (droppedSegmentId == 0) break;

        bleTransport.reportBufferOverflow();
        Serial.printf("[Main] Dropped segment %u for overflow (dropped total: %u)\n",
                      droppedSegmentId, buffer.droppedSegmentCount());
        stored = storeNewest();
    }

    if (!stored) {
        Serial.println(
            "[Main] PSRAM buffer empty but newest segment still could not be stored. Segment lost.");
    } else {
        Serial.printf("[Main] Stored segment %u: %u bytes (buffered: %u)\n", segmentId,
                      (unsigned)segmentPos, (unsigned)buffer.count());
        Serial.println(bleTransport.isConnected() ? "[Main] BLE connected — sending"
                                                  : "[Main] No BLE connection — waiting");
        bleTransport.requestBufferStatus();
    }

    indicators.setBlinking(false);

    // Ready for the next segment
    segmentPos = 0;
    energySum = 0;
    energyFrameCount = 0;
    segmentCrcAccumulator = EchoBleProtocol::CRC32_INITIAL_VALUE;
    vad.reset();
    preBufferCount = 0;
    preBufferWriteIdx = 0;
    state = STATE_IDLE;
    Serial.println("[Main] Ready for next speech segment");
}
