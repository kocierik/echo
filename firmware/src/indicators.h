#pragma once

#include <Arduino.h>
#include "config.h"

static constexpr uint8_t LED_ON = LOW;
static constexpr uint8_t LED_OFF = HIGH;

/**
 * LED indicator driven by externally owned recording and mute state.
 * - LED: ON during active recording, blinks when buffering.
 * - Muted: double-blinks every two seconds.
 */

class Indicators {
public:
    void begin();
    void update();

    /** Set LED state based on recording activity. */
    void setRecording(bool active);

    /** Set LED to blink mode (buffering, WiFi reconnecting). */
    void setBlinking(bool active);

    /** Reflect the app-controlled privacy state. */
    void setMuted(bool muted);

    /** LED on for `durationMs`: a photo is being taken. */
    void flash(uint16_t durationMs);

    bool isMuted() const { return _muted; }

private:
    bool _recording = false;
    bool _blinking = false;
    bool _muted = false;
    uint32_t _lastBlinkMs = 0;
    uint32_t _flashUntilMs = 0;
    bool _ledState = false;
};

// Implementation

void Indicators::begin() {
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LED_OFF);

    _muted = false;
    Serial.println("[IO] LED initialized");
}

void Indicators::update() {
    // --- LED control ---
    if (_flashUntilMs != 0) {
        if (static_cast<int32_t>(millis() - _flashUntilMs) < 0) {
            digitalWrite(LED_PIN, LED_ON);
            return;
        }
        _flashUntilMs = 0;
    }

    if (_muted) {
        // Double-blink every 2s to indicate muted state
        uint32_t phase = millis() % 2000;
        bool on = (phase < 100) || (phase > 200 && phase < 300);
        digitalWrite(LED_PIN, on ? LED_ON : LED_OFF);
        return;
    }

    if (_blinking) {
        // Slow blink for buffering/reconnecting
        if (millis() - _lastBlinkMs >= 500) {
            _lastBlinkMs = millis();
            _ledState = !_ledState;
            digitalWrite(LED_PIN, _ledState ? LED_ON : LED_OFF);
        }
    } else if (_recording) {
        // Solid ON during recording
        digitalWrite(LED_PIN, LED_ON);
    } else {
        // OFF when idle
        digitalWrite(LED_PIN, LED_OFF);
    }
}

void Indicators::setRecording(bool active) {
    _recording = active;
    if (!_blinking && !_muted) {
        digitalWrite(LED_PIN, active ? LED_ON : LED_OFF);
    }
}

void Indicators::setBlinking(bool active) {
    _blinking = active;
    if (!active && !_recording) {
        digitalWrite(LED_PIN, LED_OFF);
    }
}

void Indicators::setMuted(bool muted) {
    _muted = muted;
    if (_muted) {
        digitalWrite(LED_PIN, LED_OFF);
    } else if (_recording) {
        digitalWrite(LED_PIN, LED_ON);
    } else {
        digitalWrite(LED_PIN, LED_OFF);
    }
}

void Indicators::flash(uint16_t durationMs) {
    _flashUntilMs = millis() + durationMs;
    if (_flashUntilMs == 0) _flashUntilMs = 1;
    digitalWrite(LED_PIN, LED_ON);
}
