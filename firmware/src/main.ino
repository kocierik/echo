/**
 * Echo — Second Brain AI Wearable
 * Firmware for Seeed Studio XIAO ESP32-S3 Sense
 *
 * Main loop:
 * 1. Capture PCM audio from PDM microphone (I2S)
 * 2. Run VAD to detect speech
 * 3. Encode speech to Opus (opus_segment.h)
 * 4. Store every completed segment in PSRAM
 * 5. Relay the oldest segment over BLE
 * 6. Keep capture active while BLE advances incrementally
 * 7. On TAKE_PHOTO from the app, take a photo (camera task, core 0) and relay it
 *    before the audio; it stays in RAM only until the app confirms the upload
 * 8. On OTA_BEGIN, pause capture and write the new firmware to the other app slot;
 *    after the restart it is kept only once the app talks to it (ota_health.h)
 * 9. Muted, the microphone's driver is stopped. Turned off (app or a 5 s hold), Echo keeps
 *    what it was hearing, moves PSRAM to the card or waits for the phone, then deep-sleeps;
 *    a 1.5 s hold turns it on (power_off_policy.h, wake_gate.h)
 */

#include <esp_ota_ops.h>
#include <esp_sleep.h>
#include <driver/rtc_io.h>

#include "config.h"
#include "audio_capture.h"
#include "vad.h"
#include "opus_codec.h"
#include "opus_segment.h"
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
#include "power_off_policy.h"
#include "wake_gate.h"
#include "wake_window.h"
#if WAKE_WORD_ENABLED
#include "wake_detector.h"
#endif

// ============================================================
// Global instances
// ============================================================
AudioCapture audio;
VAD vad;
OpusCodec opusCodec;
OpusSegmentWriter<OpusCodec> opusWriter(opusCodec);

// libopus keeps its scratch on the stack: the loop's default 8 KB is too little
SET_LOOP_TASK_STACK_SIZE(48 * 1024);
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
ButtonGesture button(BUTTON_DEBOUNCE_MS, BUTTON_LONG_PRESS_MS, BUTTON_POWER_OFF_MS);
PowerOffPolicy powerOff;
OtaHealthCheck otaHealth(OTA_CONFIRM_TIMEOUT_MS);
WakeWindow wakeWindow(WAKE_WINDOW_MS);
#if WAKE_WORD_ENABLED
WakeDetector wakeDetector;
#endif
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
// A VAD frame of 512 samples completes at most two 20 ms Opus frames
uint8_t encodedFrame[2 * OpusSegment::MAX_FRAME_BYTES];

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

// The microphone did not restart after a standby: Echo reports itself muted
bool micFailed = false;

// What the app asked over BLE: acted on by the loop, outside the transport's update
enum PowerRequest : uint8_t { POWER_REQUEST_NONE, POWER_REQUEST_OFF, POWER_REQUEST_CANCEL };
volatile PowerRequest powerRequest = POWER_REQUEST_NONE;

// How long a VAD frame takes to process: checks 80 MHz keeps up (32 ms of audio a frame)
uint32_t frameUsMax = 0;
uint64_t frameUsTotal = 0;
uint32_t frameCount = 0;

void discardInProgressCapture();
void finalizeSegment();
void handlePowerOff(bool turnOff);
void appendEncoded(size_t bytes);
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

/** A segment reaching the card: its capture time as unix seconds, once the app has set the
 *  time (the card keeps it through deep sleep, which restarts millis). */
bool cardClock(uint32_t capturedAtMs, uint32_t& unixSeconds) {
    return bleTransport.unixSecondsAt(capturedAtMs, unixSeconds);
}

void fatal(const char* message) {
    Serial.println(message);
    if (otaHealth.onTrial()) {
        Serial.println("[OTA] new firmware failed to start: rolling back");
        esp_ota_mark_app_invalid_rollback_and_reboot();
    }
    // Not forever: a start that failed once (the radio, the card) often works the next time
    delay(FATAL_RESTART_DELAY_MS);
    ESP.restart();
    while (true) { delay(1000); }
}

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
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, HIGH);
    gpio_hold_dis(static_cast<gpio_num_t>(LED_PIN));
    rtc_gpio_deinit(static_cast<gpio_num_t>(BUTTON_PIN));
    pinMode(BUTTON_PIN, INPUT_PULLUP);

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
#if WAKE_WORD_ENABLED
        wakeDetector.reset();
#endif
        return;
    }
    micFailed = true;
    indicators.setMuted(true);
    bleTransport.setMuted(true);
    Serial.println("[Audio] microphone did not restart: reported as muted");
}

void handleTakePhoto(void*) {
    if (bleTransport.otaInProgress()) {
        bleTransport.reportPhotoFailed(EchoBleProtocol::PHOTO_FAILED_BUSY);
    } else if (powerOff.state() != PowerOffPolicy::State::ON) {
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

// The microphone's gain: MIC_GAIN until the app sets another (saved in Preferences)
uint8_t micGain = MIC_GAIN;

void handleMicGain(uint8_t gain, void*) {
    micGain = gain;
    if (!devicePreferences.saveMicGain(gain)) Serial.println("[Audio] Failed to persist mic gain");
}

void handleMuteCommand(bool muted, void*) {
    micFailed = false;
    const bool changed = muteState.isMuted() != muted;
    const bool persisted = muteState.setMuted(muted);

    if (changed) discardInProgressCapture();
    if (muteState.isMuted()) dropPhotoForPrivacy();

    indicators.setMuted(muteState.isMuted());
    bleTransport.setMuted(muteState.isMuted());
    syncMicrophone();

    if (!persisted) {
        Serial.println("[Privacy] Failed to persist mute state");
    }
    Serial.printf("[Privacy] Mute: %s\n", muteState.isMuted() ? "ON" : "OFF");
}

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
    disableLoopWDT();  // it waits below for the button's release, however long
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

// ============================================================
// Setup
// ============================================================
void setup() {
    checkButtonWake();
    setCpuFrequencyMhz(CPU_FREQ_MHZ);
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
    bleTransport.setMicGainCallback(handleMicGain, nullptr);
    bleTransport.setPowerOffCallback(handlePowerOffCommand, nullptr);

    if (!devicePreferences.begin()) {
        Serial.println("[Privacy] Preferences init failed; defaulting to listening");
    }
    micGain = devicePreferences.loadMicGain(MIC_GAIN);
    if (micGain < 1 || micGain > EchoBleProtocol::MAX_MIC_GAIN) micGain = MIC_GAIN;
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
        buffer.setClock(cardClock);
        Serial.printf("[SD] speech overflow on the card, encrypted (%llu KB waiting)\n",
                      static_cast<unsigned long long>(sdLog.pendingBytes() / 1024));
    } else if (sdStaging != nullptr) {
        Serial.println("[SD] card not used: its key could not be loaded");
    }

    // Initialize audio capture
    // Muted, the microphone stays off until listening resumes (syncMicrophone)
    if (!muteState.isMuted() && !audio.begin()) fatal("[FATAL] Audio capture init failed");

    if (!opusCodec.begin()) fatal("[FATAL] Opus encoder init failed");
#if WAKE_WORD_ENABLED
    // Never fatal: without it Echo listens as before, and a firmware on trial stays
    wakeDetector.begin();
#endif
    vad.reset();

    indicators.setBlinking(false);
    // A loop that stops for 5 s (the core's watchdog timeout) restarts Echo: a stuck
    // driver or a deadlock no longer needs the battery pulled
    enableLoopWDT();
    Serial.printf("[OK] System ready at %lu MHz\n", static_cast<unsigned long>(getCpuFrequencyMhz()));
}

// ============================================================
// Main Loop
// ============================================================
void loop() {
    indicators.update();
    bleTransport.update(buffer);
    const PowerRequest request = powerRequest;
    powerRequest = POWER_REQUEST_NONE;
    if (request != POWER_REQUEST_NONE) handlePowerOff(request == POWER_REQUEST_OFF);

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
            if (powerOff.state() == PowerOffPolicy::State::TURNING_OFF) {
                Serial.println("[Button] long press: keep Echo on");
                cancelPowerOff();
            } else {
                Serial.println("[Button] long press: mute toggle");
                handleMuteCommand(!(muteState.isMuted() || micFailed), nullptr);
            }
            break;
        case ButtonGesture::VERY_LONG_PRESS:
            Serial.println("[Button] very long press: turn off");
            handlePowerOff(true);
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

    if (powerOff.state() != PowerOffPolicy::State::ON) {
        continueTurningOff();
        return;
    }

    if (muteState.isMuted() || micFailed) {
        if (state != STATE_IDLE || segmentPos != 0 || preBufferCount != 0) {
            discardInProgressCapture();
        }
        // A photo that finished after muting is dropped too
        if (muteState.isMuted() && photoSlot.isReady()) dropPhotoForPrivacy();

        delay(50);
        return;
    }

    // Read audio frame from microphone
    int samplesRead = audio.readSamples(pcmBuffer, PCM_BUFFER_SIZE);
    if (samplesRead <= 0) return;
    const uint32_t frameStartedUs = micros();
    amplify(pcmBuffer, samplesRead, micGain);
    // Every frame while listening, idle or recording: the features' noise estimate needs
    // the audio around the phrase too
#if WAKE_WORD_ENABLED
    const bool wakeDetected = wakeDetector.feed(pcmBuffer, samplesRead);
#else
    const bool wakeDetected = false;
#endif

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
                appendEncoded(opusWriter.begin(encodedFrame));
                indicators.setRecording(true);
                wakeWindow.segmentStarted(segmentStartMs);

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

    if (wakeWindow.heard(wakeDetected, millis())) {
        Serial.println("[Wake] heard");
    }

    const uint32_t frameUs = micros() - frameStartedUs;
    if (frameUs > frameUsMax) frameUsMax = frameUs;
    frameUsTotal += frameUs;
    ++frameCount;
}

// ============================================================
// Helpers
// ============================================================

void discardInProgressCapture() {
    indicators.setRecording(false);
    wakeWindow.segmentEnded();
    state = STATE_IDLE;
    segmentPos = 0;
    energySum = 0;
    energyFrameCount = 0;
    segmentCrcAccumulator = EchoBleProtocol::CRC32_INITIAL_VALUE;
    opusCodec.reset();
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
    appendEncoded(opusWriter.write(samples, count, encodedFrame, sizeof(encodedFrame)));
}

/** The first `bytes` of encodedFrame onto the segment, in its CRC. */
void appendEncoded(size_t bytes) {
    if (bytes > 0 && segmentPos + bytes <= SEGMENT_MAX_SIZE) {
        memcpy(segmentBuffer + segmentPos, encodedFrame, bytes);
        segmentPos += bytes;
        segmentCrcAccumulator = EchoBleProtocol::crc32Update(
            segmentCrcAccumulator, encodedFrame, bytes);
    }
}

void finalizeSegment() {
    indicators.setRecording(false);
    // The last part of a 20 ms frame
    if (state == STATE_RECORDING) appendEncoded(opusWriter.finish(encodedFrame, sizeof(encodedFrame)));

    if (segmentPos == 0) {
        Serial.println("[Main] Empty segment, resetting");
        // Reset VAD and buffers before returning to listening
        vad.reset();
        preBufferCount = 0;
        preBufferWriteIdx = 0;
        state = STATE_IDLE;
        wakeWindow.segmentEnded();
        return;
    }

    const uint32_t durationMs = millis() - segmentStartMs;
    Serial.printf("[Main] Segment ready: %u bytes, %ums\n", (unsigned)segmentPos, durationMs);
    if (frameCount > 0) {
        Serial.printf("[Main] frame time avg=%lu us max=%lu us at %lu MHz\n",
                      static_cast<unsigned long>(frameUsTotal / frameCount),
                      static_cast<unsigned long>(frameUsMax),
                      static_cast<unsigned long>(getCpuFrequencyMhz()));
    }
    frameUsMax = 0;
    frameUsTotal = 0;
    frameCount = 0;

    const uint16_t avgEnergy =
        energyFrameCount > 0 ? static_cast<uint16_t>(energySum / energyFrameCount) : 0;
    const uint32_t segmentId = nextSegmentId++ |
        (wakeWindow.segmentHeard() ? EchoBleProtocol::WAKE_SEGMENT_ID_FLAG : 0U);
    wakeWindow.segmentEnded();
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
