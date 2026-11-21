#pragma once

#include <math.h>
#include <stddef.h>
#include <stdint.h>

/**
 * Loudness of a frame of 16-bit PCM without its constant offset.
 *
 * The XIAO ESP32-S3 Sense PDM microphone reads with a DC offset (~1400): the RMS of the
 * raw samples was mostly that offset, so silence and speech measured alike and the VAD
 * never stopped. The mean of the frame is taken away first: silence is ~0, sound is
 * what remains.
 */
inline uint32_t acRms(const int16_t* samples, size_t count) {
    if (samples == nullptr || count == 0) return 0;

    int64_t total = 0;
    for (size_t i = 0; i < count; i++) total += samples[i];
    const double mean = (double)total / (double)count;

    double sumSquares = 0;
    for (size_t i = 0; i < count; i++) {
        const double centered = (double)samples[i] - mean;
        sumSquares += centered * centered;
    }
    return (uint32_t)sqrt(sumSquares / (double)count);
}

/**
 * The microphone's samples without their offset and rumble, `gain` times louder, clipped
 * to 16 bits: a first-order high-pass at ~100 Hz (16 kHz), its state kept across frames.
 *
 * The Sense microphone reads with an offset (~1400) and is quiet: speech a metre away
 * peaked at about a tenth of full scale. Taking each 32 ms frame's own mean away left a
 * step at every frame boundary (a 31 Hz buzz under the voice) and let steps, clothes and
 * knocks through whole; the filter removes the offset continuously and keeps the voice
 * (its lowest fundamentals, ~85 Hz, lose a little; speech recognition needs none of it).
 */
class HighPass {
public:
    /** exp(-2*pi*100/16000) in Q15. */
    static constexpr int32_t COEFFICIENT = 31508;

    /** The microphone restarted: the next sample is the new start, without a jump. */
    void reset() { _primed = false; }

    void process(int16_t* samples, size_t count, int32_t gain) {
        if (samples == nullptr) return;
        for (size_t i = 0; i < count; i++) {
            const int32_t x = samples[i];
            if (!_primed) {
                _previousIn = x;
                _previousOut = 0;
                _primed = true;
            }
            const int64_t y =
                (static_cast<int64_t>(COEFFICIENT) * (_previousOut + x - _previousIn)) >> 15;
            _previousIn = x;
            _previousOut = static_cast<int32_t>(y);
            int64_t value = y * gain;
            if (value > 32767) value = 32767;
            if (value < -32768) value = -32768;
            samples[i] = static_cast<int16_t>(value);
        }
    }

private:
    int32_t _previousIn = 0;
    int32_t _previousOut = 0;
    bool _primed = false;
};
