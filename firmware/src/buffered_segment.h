#pragma once

#include <cstddef>
#include <cstdint>

#include "ble_protocol.h"

struct BufferedSegment {
    uint32_t segmentId;
    uint32_t dataLength;
    uint32_t durationMs;
    uint32_t silenceBeforeMs;
    uint32_t capturedAtMs;
    uint16_t avgEnergy;
    uint32_t crc;
};

struct BufferedSegmentCodec {
    static constexpr size_t HEADER_SIZE = 26;

    static void encode(const BufferedSegment& header, uint8_t* output) {
        EchoBleProtocol::writeU32(output, header.segmentId);
        EchoBleProtocol::writeU32(output + 4, header.dataLength);
        EchoBleProtocol::writeU32(output + 8, header.durationMs);
        EchoBleProtocol::writeU32(output + 12, header.silenceBeforeMs);
        EchoBleProtocol::writeU32(output + 16, header.capturedAtMs);
        EchoBleProtocol::writeU16(output + 20, header.avgEnergy);
        EchoBleProtocol::writeU32(output + 22, header.crc);
    }

    static BufferedSegment decode(const uint8_t* input) {
        return {
            EchoBleProtocol::readU32(input),
            EchoBleProtocol::readU32(input + 4),
            EchoBleProtocol::readU32(input + 8),
            EchoBleProtocol::readU32(input + 12),
            EchoBleProtocol::readU32(input + 16),
            EchoBleProtocol::readU16(input + 20),
            EchoBleProtocol::readU32(input + 22),
        };
    }
};