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
 * The frame without its constant offset, `gain` times louder, clipped to 16 bits.
 *
 * The Sense microphone is quiet: speech a metre away peaked at about a tenth of full
 * scale, under the VAD's threshold, and reached the transcription in fragments. The
 * offset goes first, or the gain would multiply it too.
 */
inline void amplify(int16_t* samples, size_t count, int32_t gain) {
    if (samples == nullptr || count == 0) return;

    int64_t total = 0;
    for (size_t i = 0; i < count; i++) total += samples[i];
    const int32_t mean = (int32_t)(total / (int64_t)count);

    for (size_t i = 0; i < count; i++) {
        int32_t value = ((int32_t)samples[i] - mean) * gain;
        if (value > 32767) value = 32767;
        if (value < -32768) value = -32768;
        samples[i] = (int16_t)value;
    }
}
