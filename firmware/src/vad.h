#pragma once

#include <Arduino.h>
#include "audio_level.h"
#include "config.h"

/**
 * Voice Activity Detection (VAD) module.
 * Uses energy-based threshold with smoothing to detect speech.
 */

enum VADState {
    VAD_SILENCE,    // No speech detected
    VAD_SPEECH,     // Active speech
    VAD_TRAILING,   // Speech ended, waiting for silence confirmation
};

class VAD {
public:
    /**
     * Process a frame of PCM audio and determine if speech is present.
     * @param samples PCM samples buffer.
     * @param count Number of samples.
     * @return true if currently in speech state.
     */
    bool process(const int16_t* samples, size_t count);

    /** Get current VAD state. */
    VADState getState() const { return _state; }

    /** Get current RMS energy level (for debugging). */
    uint32_t getEnergy() const { return _energy; }

    /** Check if speech just started (transition from silence to speech). */
    bool speechStarted() const { return _speechStarted; }

    /** Check if speech just ended (transition from speech to silence). */
    bool speechEnded() const { return _speechEnded; }

    /** Get duration of last silence period in ms. */
    uint32_t getLastSilenceDurationMs() const { return _lastSilenceDurationMs; }

    /** Reset VAD state. */
    void reset();

private:
    VADState _state = VAD_SILENCE;
    uint32_t _energy = 0;
    uint16_t _speechFrameCount = 0;
    uint16_t _silenceFrameCount = 0;
    bool _speechStarted = false;
    bool _speechEnded = false;
    uint32_t _silenceStartMs = 0;
    uint32_t _lastSilenceDurationMs = 0;
    uint32_t _lastDebugMs = 0;
    // Kept through reset(): the place, not the segment, sets the background
    NoiseFloor _noise{VAD_ENERGY_THRESHOLD};
    EnergyAverage _average;

};

// Implementation

bool VAD::process(const int16_t* samples, size_t count) {
    _speechStarted = false;
    _speechEnded = false;

    // Without the microphone's constant offset: silence ~0, speech what remains
    _energy = acRms(samples, count);
    const uint32_t level = _average.update(_energy);
    const uint32_t threshold = _noise.update(level);
    bool frameHasSpeech = (level > threshold);

    if (_state == VAD_SILENCE && millis() - _lastDebugMs > 5000) {
        Serial.printf("[VAD] idle energy: %u (floor: %u, threshold: %u)\n", _energy,
                      _noise.floor(), threshold);
        _lastDebugMs = millis();
    }

    switch (_state) {
        case VAD_SILENCE:
            if (frameHasSpeech) {
                _speechFrameCount++;
                if (_speechFrameCount >= VAD_SPEECH_START_FRAMES) {
                    _state = VAD_SPEECH;
                    _speechStarted = true;
                    _silenceFrameCount = 0;
                    // Calculate how long we were silent
                    if (_silenceStartMs > 0) {
                        _lastSilenceDurationMs = millis() - _silenceStartMs;
                    }
                    Serial.printf("[VAD] Speech START (energy: %u)\n", _energy);
                }
            } else {
                _speechFrameCount = 0;
            }
            break;

        case VAD_SPEECH:
            if (!frameHasSpeech) {
                _silenceFrameCount++;
                if (_silenceFrameCount >= VAD_SPEECH_END_FRAMES) {
                    _state = VAD_SILENCE;
                    _speechEnded = true;
                    _speechFrameCount = 0;
                    _silenceStartMs = millis();
                    Serial.printf("[VAD] Speech END (silence frames: %u)\n", _silenceFrameCount);
                }
            } else {
                _silenceFrameCount = 0;
            }
            break;
    }

    return (_state == VAD_SPEECH);
}

void VAD::reset() {
    _state = VAD_SILENCE;
    _energy = 0;
    _speechFrameCount = 0;
    _silenceFrameCount = 0;
    _speechStarted = false;
    _speechEnded = false;
    _silenceStartMs = millis();
    _lastSilenceDurationMs = 0;
    _lastDebugMs = 0;
    _average.reset();
}
