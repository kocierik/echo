#pragma once

#include <cstddef>
#include <cstdint>

#include "ble_protocol.h"

struct BufferedSegment {
    uint32_t segmentId;
    uint32_t dataLength;
    uint32_t durationMs;
    uint32_t silenceBeforeMs;
    // millis() of the boot that captured it; with `unixTime`, unix seconds instead, or 0
    // when the time was unknown (the phone then gets the time it is delivered)
    uint32_t capturedAtMs;
    uint16_t avgEnergy;
    uint32_t crc;
    // Set on the microSD (TieredQueue), whose records outlive the boot. No default member
    // initializer: the native tests build as C++11, where one ends aggregate initialization;
    // brace-initialized headers that leave it out get false.
    bool unixTime;
};

struct BufferedSegmentCodec {
    static constexpr size_t HEADER_SIZE = 26;

    // `unixTime` rides in the top bit of the durationMs field, keeping the 26-byte layout:
    // segments close at SEGMENT_DURATION_MS (25 s) and photos carry 0, far below 2^31 ms
    // (~24 days). Records written before the flag have the bit clear: boot-relative.
    static constexpr uint32_t UNIX_TIME_FLAG = 0x80000000U;

    static void encode(const BufferedSegment& header, uint8_t* output) {
        EchoBleProtocol::writeU32(output, header.segmentId);
        EchoBleProtocol::writeU32(output + 4, header.dataLength);
        EchoBleProtocol::writeU32(output + 8, (header.durationMs & ~UNIX_TIME_FLAG) |
                                                  (header.unixTime ? UNIX_TIME_FLAG : 0U));
        EchoBleProtocol::writeU32(output + 12, header.silenceBeforeMs);
        EchoBleProtocol::writeU32(output + 16, header.capturedAtMs);
        EchoBleProtocol::writeU16(output + 20, header.avgEnergy);
        EchoBleProtocol::writeU32(output + 22, header.crc);
    }

    static BufferedSegment decode(const uint8_t* input) {
        const uint32_t duration = EchoBleProtocol::readU32(input + 8);
        return {
            EchoBleProtocol::readU32(input),
            EchoBleProtocol::readU32(input + 4),
            duration & ~UNIX_TIME_FLAG,
            EchoBleProtocol::readU32(input + 12),
            EchoBleProtocol::readU32(input + 16),
            EchoBleProtocol::readU16(input + 20),
            EchoBleProtocol::readU32(input + 22),
            (duration & UNIX_TIME_FLAG) != 0,
        };
    }
};

/** When the segment was recorded, in unix seconds: its own time when it carries one; the
 *  delivery time (`nowMs`) when that time was unknown; else its capture millis through
 *  this boot's anchor. False while the anchor is needed but not set. */
inline bool resolveRecordedAt(const BufferedSegment& segment,
                              const EchoBleProtocol::TimeAnchor& anchor, uint32_t nowMs,
                              uint64_t& unixSeconds) {
    if (segment.unixTime) {
        if (segment.capturedAtMs != 0) {
            unixSeconds = segment.capturedAtMs;
            return true;
        }
        return anchor.resolveUnixSeconds(nowMs, unixSeconds);
    }
    return anchor.resolveUnixSeconds(segment.capturedAtMs, unixSeconds);
}