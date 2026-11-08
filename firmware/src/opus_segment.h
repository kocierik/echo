#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/**
 * A segment's speech as Opus (firmware 0.9 on), in place of IMA-ADPCM: about 2 KB a
 * second instead of 8, so the Bluetooth, the buffer and the card carry a quarter.
 *
 * The segment starts with MAGIC, then each 20 ms frame as one byte of length and its
 * packet. The server tells it from ADPCM by MAGIC (backend/app/services/segment_audio.py);
 * the app forwards the bytes as they are.
 */
namespace OpusSegment {
constexpr uint8_t MAGIC[4] = {'E', 'O', 'P', '1'};
constexpr size_t MAGIC_SIZE = sizeof(MAGIC);
constexpr size_t FRAME_SAMPLES = 320;  // 20 ms at 16 kHz
constexpr size_t MAX_PACKET = 255;     // its length fits in one byte
// What one frame written can take: its length byte and its packet
constexpr size_t MAX_FRAME_BYTES = 1 + MAX_PACKET;
}  // namespace OpusSegment

/**
 * Cuts the microphone's samples into 20 ms frames and writes each through `Codec`
 * (OpusCodec on the wearable, a fake in the native tests): `reset()` and
 * `encode(pcm, samples, out, capacity)` returning the packet's size, or <= 0.
 */
template <typename Codec>
class OpusSegmentWriter {
public:
    explicit OpusSegmentWriter(Codec& codec) : _codec(codec) {}

    /** A new segment: the codec starts afresh, MAGIC goes first. */
    size_t begin(uint8_t* out) {
        _codec.reset();
        _pending = 0;
        memcpy(out, OpusSegment::MAGIC, OpusSegment::MAGIC_SIZE);
        return OpusSegment::MAGIC_SIZE;
    }

    /** Samples in; the frames they complete out, at most `capacity` bytes. */
    size_t write(const int16_t* samples, size_t count, uint8_t* out, size_t capacity) {
        size_t written = 0;
        for (size_t i = 0; i < count; i++) {
            _frame[_pending++] = samples[i];
            if (_pending == OpusSegment::FRAME_SAMPLES) {
                written += emit(out + written, capacity - written);
                _pending = 0;
            }
        }
        return written;
    }

    /** The segment's last part of a frame, filled with silence. */
    size_t finish(uint8_t* out, size_t capacity) {
        if (_pending == 0) return 0;
        memset(_frame + _pending, 0, (OpusSegment::FRAME_SAMPLES - _pending) * sizeof(int16_t));
        _pending = 0;
        return emit(out, capacity);
    }

private:
    size_t emit(uint8_t* out, size_t capacity) {
        if (capacity < 2) return 0;
        const size_t room =
            capacity - 1 < OpusSegment::MAX_PACKET ? capacity - 1 : OpusSegment::MAX_PACKET;
        const int size = _codec.encode(_frame, OpusSegment::FRAME_SAMPLES, out + 1, room);
        if (size <= 0) return 0;  // a frame the codec refused: dropped, the next ones go on
        out[0] = static_cast<uint8_t>(size);
        return 1 + static_cast<size_t>(size);
    }

    Codec& _codec;
    int16_t _frame[OpusSegment::FRAME_SAMPLES] = {};
    size_t _pending = 0;
};
