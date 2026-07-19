#pragma once

#include <Arduino.h>

/**
 * IMA-ADPCM encoder.
 * Compresses 16-bit PCM to 4-bit ADPCM (4:1 compression ratio).
 */

class ADPCMEncoder {
public:
    /** Reset encoder state (call at start of new segment). */
    void reset();

    /**
     * Encode PCM samples to ADPCM.
     * @param pcm Input PCM samples (16-bit signed).
     * @param pcmCount Number of PCM samples.
     * @param adpcm Output ADPCM buffer (must be at least pcmCount/2 bytes).
     * @return Number of ADPCM bytes written.
     */
    size_t encode(const int16_t* pcm, size_t pcmCount, uint8_t* adpcm);

private:
    int16_t _prevSample = 0;
    int8_t _index = 0;

    int8_t encodeSample(int16_t sample);
};

// IMA-ADPCM step table
static const int16_t _stepTable[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

// Index adjustment table
static const int8_t _indexTable[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

// Implementation

void ADPCMEncoder::reset() {
    _prevSample = 0;
    _index = 0;
}

int8_t ADPCMEncoder::encodeSample(int16_t sample) {
    int32_t diff = sample - _prevSample;
    uint8_t nibble = 0;

    int16_t step = _stepTable[_index];

    if (diff < 0) {
        nibble = 8;
        diff = -diff;
    }

    // Quantize
    if (diff >= step) { nibble |= 4; diff -= step; }
    step >>= 1;
    if (diff >= step) { nibble |= 2; diff -= step; }
    step >>= 1;
    if (diff >= step) { nibble |= 1; }

    // Reconstruct for predictor update
    int32_t diffq = _stepTable[_index] >> 3;
    if (nibble & 4) diffq += _stepTable[_index];
    if (nibble & 2) diffq += _stepTable[_index] >> 1;
    if (nibble & 1) diffq += _stepTable[_index] >> 2;

    if (nibble & 8) {
        _prevSample -= diffq;
    } else {
        _prevSample += diffq;
    }

    // Clamp
    if (_prevSample > 32767) _prevSample = 32767;
    if (_prevSample < -32768) _prevSample = -32768;

    // Update index
    _index += _indexTable[nibble];
    if (_index < 0) _index = 0;
    if (_index > 88) _index = 88;

    return nibble;
}

size_t ADPCMEncoder::encode(const int16_t* pcm, size_t pcmCount, uint8_t* adpcm) {
    size_t adpcmBytes = 0;

    for (size_t i = 0; i < pcmCount; i += 2) {
        uint8_t byte = 0;
        byte = encodeSample(pcm[i]) & 0x0F;
        if (i + 1 < pcmCount) {
            byte |= (encodeSample(pcm[i + 1]) << 4);
        }
        adpcm[adpcmBytes++] = byte;
    }

    return adpcmBytes;
}
