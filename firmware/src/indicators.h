#pragma once

#include <Arduino.h>
#include "config.h"
#include "indicator_state.h"

static constexpr uint8_t LED_ON = LOW;
static constexpr uint8_t LED_OFF = HIGH;

/**
 * LED indicator and mute button handler.
 * - LED: ON during active recording, blinks when buffering.
 * - Mute button: hardware toggle for privacy.
 */

class Indicators {
public:
    void begin();
    void update();

    /** Set LED state based on recording activity. */
    void setRecording(bool active);

    /** Set LED to blink mode (buffering, WiFi reconnecting). */
    void setBlinking(bool active);

    /** Check if mute button is pressed (device should not record). */
    bool isMuted() const { return _muted; }

private:
    bool _recording = false;
    bool _blinking = false;
    bool _muted = false;
    ButtonDebouncer _button{true, MUTE_DEBOUNCE_MS};
    uint32_t _lastBlinkMs = 0;
    bool _ledState = false;
};

// Implementation

void Indicators::begin() {
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LED_OFF);

    pinMode(MUTE_BUTTON_PIN, INPUT_PULLUP);
    _muted = false;
    _button = ButtonDebouncer(digitalRead(MUTE_BUTTON_PIN) == HIGH, MUTE_DEBOUNCE_MS);

    Serial.println("[IO] LED and mute button initialized");
}

void Indicators::update() {
    if (_button.update(digitalRead(MUTE_BUTTON_PIN) == HIGH, millis())) {
        _muted = !_muted;
        Serial.printf("[IO] Mute: %s\n", _muted ? "ON" : "OFF");
        if (_muted) digitalWrite(LED_PIN, LED_OFF);
    }

    // --- LED control ---
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
