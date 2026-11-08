#pragma once

#include <opus.h>

#include "opus_segment.h"

/**
 * libopus on the wearable (sh123/esp32_opus: fixed point, its scratch on the stack, so
 * the loop task runs with a larger stack, main.ino). Speech at 16 kHz, 16 kbit/s: plenty
 * for the transcription, which is what the audio is for (deleted a day after).
 */
class OpusCodec {
public:
    bool begin() {
        int error = OPUS_OK;
        _encoder = opus_encoder_create(16000, 1, OPUS_APPLICATION_VOIP, &error);
        if (error != OPUS_OK || _encoder == nullptr) {
            _encoder = nullptr;
            return false;
        }
        opus_encoder_ctl(_encoder, OPUS_SET_BITRATE(16000));
        opus_encoder_ctl(_encoder, OPUS_SET_COMPLEXITY(3));
        opus_encoder_ctl(_encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
        return true;
    }

    void reset() {
        if (_encoder != nullptr) opus_encoder_ctl(_encoder, OPUS_RESET_STATE);
    }

    int encode(const int16_t* pcm, size_t samples, uint8_t* out, size_t capacity) {
        if (_encoder == nullptr) return -1;
        return opus_encode(_encoder, pcm, static_cast<int>(samples), out,
                           static_cast<opus_int32>(capacity));
    }

private:
    OpusEncoder* _encoder = nullptr;
};
