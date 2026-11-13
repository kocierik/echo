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

    /** The LED the other way for `durationMs`: the wake phrase was heard. While recording
     *  the LED is on, so a flash would not show: it goes dark for a moment instead. */
    void wink(uint16_t durationMs);

    /** The vibration motor for `durationMs`, when one is fitted (HAPTIC_PIN); never blocks. */
    void pulse(uint16_t durationMs);

    bool isMuted() const { return _muted; }

    /** The LED pin (GPIO21) is the microSD's chip select: with a card mounted the LED is
     *  never driven again, so it cannot disturb the card. */
    void release();

private:
    void writeLed(uint8_t level);

    bool _released = false;
    bool _recording = false;
    bool _blinking = false;
    bool _muted = false;
    uint32_t _lastBlinkMs = 0;
    uint32_t _flashUntilMs = 0;
    uint32_t _winkUntilMs = 0;
    uint32_t _pulseUntilMs = 0;
    bool _ledState = false;
};

// Implementation

void Indicators::release() {
    // The microSD's chip select from now on: never driven again
    _released = true;
    Serial.println("[IO] LED released: GPIO21 is the SD card's chip select");
}

void Indicators::writeLed(uint8_t level) {
    if (_winkUntilMs != 0) {
        // Cleared once over, or the comparison would turn true again after the wrap
        if (static_cast<int32_t>(millis() - _winkUntilMs) < 0) {
            level = level == LED_ON ? LED_OFF : LED_ON;
        } else {
            _winkUntilMs = 0;
        }
    }
#if FEEDBACK_LED_PIN >= 0
    // An LED of its own (active high): it works with a microSD mounted
    digitalWrite(FEEDBACK_LED_PIN, level == LED_ON ? HIGH : LOW);
#else
    if (!_released) digitalWrite(LED_PIN, level);
#endif
}

void Indicators::begin() {
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LED_OFF);
#if FEEDBACK_LED_PIN >= 0
    pinMode(FEEDBACK_LED_PIN, OUTPUT);
    digitalWrite(FEEDBACK_LED_PIN, LOW);
#endif
#if HAPTIC_PIN >= 0
    pinMode(HAPTIC_PIN, OUTPUT);
    digitalWrite(HAPTIC_PIN, LOW);
#endif

    _muted = false;
    Serial.println("[IO] LED initialized");
}

void Indicators::update() {
#if HAPTIC_PIN >= 0
    if (_pulseUntilMs != 0 && static_cast<int32_t>(millis() - _pulseUntilMs) >= 0) {
        _pulseUntilMs = 0;
        digitalWrite(HAPTIC_PIN, LOW);
    }
#endif
    if (_released && FEEDBACK_LED_PIN < 0) return;
    // --- LED control ---
    if (_flashUntilMs != 0) {
        if (static_cast<int32_t>(millis() - _flashUntilMs) < 0) {
            writeLed(LED_ON);
            return;
        }
        _flashUntilMs = 0;
    }

    if (_muted) {
        // Double-blink every 2s to indicate muted state
        uint32_t phase = millis() % 2000;
        bool on = (phase < 100) || (phase > 200 && phase < 300);
        writeLed(on ? LED_ON : LED_OFF);
        return;
    }

    if (_blinking) {
        // Slow blink for buffering/reconnecting
        if (millis() - _lastBlinkMs >= 500) {
            _lastBlinkMs = millis();
            _ledState = !_ledState;
            writeLed(_ledState ? LED_ON : LED_OFF);
        }
    } else if (_recording) {
        // Solid ON during recording
        writeLed(LED_ON);
    } else {
        // OFF when idle
        writeLed(LED_OFF);
    }
}

void Indicators::setRecording(bool active) {
    _recording = active;
    if (!_blinking && !_muted) {
        writeLed(active ? LED_ON : LED_OFF);
    }
}

void Indicators::setBlinking(bool active) {
    _blinking = active;
    if (!active && !_recording) {
        writeLed(LED_OFF);
    }
}

void Indicators::setMuted(bool muted) {
    _muted = muted;
    if (_muted) {
        writeLed(LED_OFF);
    } else if (_recording) {
        writeLed(LED_ON);
    } else {
        writeLed(LED_OFF);
    }
}

void Indicators::wink(uint16_t durationMs) {
    _winkUntilMs = millis() + durationMs;
    if (_winkUntilMs == 0) _winkUntilMs = 1;
    writeLed(_recording && !_muted ? LED_ON : LED_OFF);  // shown inverted until then
}

void Indicators::pulse(uint16_t durationMs) {
#if HAPTIC_PIN >= 0
    _pulseUntilMs = millis() + durationMs;
    if (_pulseUntilMs == 0) _pulseUntilMs = 1;
    digitalWrite(HAPTIC_PIN, HIGH);
#else
    (void)durationMs;
#endif
}

void Indicators::flash(uint16_t durationMs) {
    _flashUntilMs = millis() + durationMs;
    if (_flashUntilMs == 0) _flashUntilMs = 1;
    writeLed(LED_ON);
}
