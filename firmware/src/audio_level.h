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

/**
 * The background's loudness, followed as it changes, and the level speech must clear.
 *
 * Fed the half-second average (EnergyAverage), not single frames: the pendant's background
 * swings from frame to frame (~70 to ~420 on the wearable) and some frame in every 1.4 s
 * cleared any threshold, so Echo recorded without pause and most segments came back empty.
 * The floor follows the quiet: down fast (an eighth of the way each frame), up slowly
 * (1/1024, about half a minute), so speech barely lifts it. Speech must be 1.4 times the
 * floor (+3 dB) and never under `minimum`: in a quiet or ordinary place the minimum
 * decides, in a loud one the floor. Chosen on 12.5 minutes of the wearable's own audio:
 * noise recorded about a third of the time instead of always, 90% of speech segments kept
 * (1.6 kept 83% and took no more noise away).
 */
class NoiseFloor {
public:
    explicit NoiseFloor(uint32_t minimum) : _minimum(minimum) {}

    /** One frame's energy (acRms); the threshold for it. */
    uint32_t update(uint32_t energy) {
        if (_floor == 0) {
            _floor = energy > 0 ? energy : 1;
        } else if (energy < _floor) {
            _floor -= (_floor - energy + 7) / 8;
        } else {
            _floor += (energy - _floor) / 1024;
        }
        return threshold();
    }

    uint32_t threshold() const {
        const uint32_t relative = _floor * 7 / 5;
        return relative > _minimum ? relative : _minimum;
    }

    uint32_t floor() const { return _floor; }

private:
    uint32_t _minimum;
    uint32_t _floor = 0;
};

/** The mean energy of the last `FRAMES` frames (~0.5 s at 32 ms): what the VAD compares. */
class EnergyAverage {
public:
    static constexpr size_t FRAMES = 16;

    uint32_t update(uint32_t energy) {
        _sum -= _frames[_next];
        _frames[_next] = energy;
        _sum += energy;
        _next = (_next + 1) % FRAMES;
        if (_count < FRAMES) _count++;
        return static_cast<uint32_t>(_sum / _count);
    }

    void reset() {
        for (size_t i = 0; i < FRAMES; i++) _frames[i] = 0;
        _sum = 0;
        _next = 0;
        _count = 0;
    }

private:
    uint32_t _frames[FRAMES] = {};
    uint64_t _sum = 0;
    size_t _next = 0;
    size_t _count = 0;
};

