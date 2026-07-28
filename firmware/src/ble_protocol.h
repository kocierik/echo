#pragma once

#include <cstddef>
#include <cstdint>

namespace EchoBleProtocol {

constexpr uint8_t FRAME_SEGMENT_START = 0x01;
constexpr uint8_t FRAME_SEGMENT_METADATA = 0x02;
constexpr uint8_t FRAME_SEGMENT_DATA = 0x03;
constexpr uint8_t FRAME_READY = 0x10;
constexpr uint8_t FRAME_ACK_WINDOW = 0x11;
constexpr uint8_t FRAME_RESTART_SEGMENT = 0x12;
constexpr uint8_t FRAME_UPLOAD_OK = 0x13;
constexpr uint8_t FRAME_SET_TIME = 0x14;
constexpr uint8_t FRAME_DEVICE_STATUS = 0x20;
constexpr uint8_t PROTOCOL_VERSION = 1;

constexpr size_t SEGMENT_START_SIZE = 20;
constexpr size_t SEGMENT_METADATA_SIZE = 19;
constexpr size_t SEGMENT_DATA_HEADER_SIZE = 7;
constexpr size_t READY_SIZE = 1;
constexpr size_t ACK_WINDOW_SIZE = 7;
constexpr size_t SEGMENT_COMMAND_SIZE = 5;
constexpr size_t SET_TIME_SIZE = 11;
constexpr size_t DEVICE_STATUS_SIZE = 8;
constexpr size_t MAX_CONTROL_FRAME_SIZE = SET_TIME_SIZE;
constexpr size_t ATT_NOTIFICATION_OVERHEAD = 3;
constexpr size_t NIMBLE_CHARACTERISTIC_MAX_LENGTH = 512;
constexpr uint32_t CRC32_INITIAL_VALUE = 0xFFFFFFFFU;

inline size_t notificationValueSizeForMtu(
        uint16_t mtu,
        size_t characteristicMaxLength = NIMBLE_CHARACTERISTIC_MAX_LENGTH) {
    if (mtu <= ATT_NOTIFICATION_OVERHEAD) return 0;
    const size_t attPayload = static_cast<size_t>(mtu) - ATT_NOTIFICATION_OVERHEAD;
    return attPayload < characteristicMaxLength ? attPayload : characteristicMaxLength;
}

inline size_t segmentDataPayloadSizeForMtu(
        uint16_t mtu,
        size_t characteristicMaxLength = NIMBLE_CHARACTERISTIC_MAX_LENGTH) {
    const size_t valueSize = notificationValueSizeForMtu(mtu, characteristicMaxLength);
    return valueSize > SEGMENT_DATA_HEADER_SIZE ? valueSize - SEGMENT_DATA_HEADER_SIZE : 0;
}

inline void writeU16(uint8_t* output, uint16_t value) {
    output[0] = static_cast<uint8_t>(value);
    output[1] = static_cast<uint8_t>(value >> 8);
}

inline void writeU32(uint8_t* output, uint32_t value) {
    for (size_t index = 0; index < 4; ++index) {
        output[index] = static_cast<uint8_t>(value >> (index * 8));
    }
}

inline void writeU64(uint8_t* output, uint64_t value) {
    for (size_t index = 0; index < 8; ++index) {
        output[index] = static_cast<uint8_t>(value >> (index * 8));
    }
}

inline uint16_t readU16(const uint8_t* input) {
    return static_cast<uint16_t>(input[0]) |
           (static_cast<uint16_t>(input[1]) << 8);
}

inline uint32_t readU32(const uint8_t* input) {
    uint32_t value = 0;
    for (size_t index = 0; index < 4; ++index) {
        value |= static_cast<uint32_t>(input[index]) << (index * 8);
    }
    return value;
}

inline uint64_t readU64(const uint8_t* input) {
    uint64_t value = 0;
    for (size_t index = 0; index < 8; ++index) {
        value |= static_cast<uint64_t>(input[index]) << (index * 8);
    }
    return value;
}

inline uint32_t crc32Update(uint32_t crc, const uint8_t* data, size_t length) {
    for (size_t index = 0; index < length; ++index) {
        crc ^= data[index];
        for (uint8_t bit = 0; bit < 8; ++bit) {
            crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
        }
    }
    return crc;
}

inline uint32_t crc32Finalize(uint32_t crc) {
    return ~crc;
}

inline uint32_t crc32(const uint8_t* data, size_t length) {
    return crc32Finalize(crc32Update(CRC32_INITIAL_VALUE, data, length));
}

struct SegmentStart {
    uint32_t segmentId;
    uint8_t protocolVersion;
    uint32_t totalLength;
    uint32_t durationMs;
    uint16_t totalChunks;
    uint32_t crc;
};

struct SegmentMetadata {
    uint32_t segmentId;
    uint64_t recordedAtUnixSeconds;
    uint32_t silenceBeforeMs;
    uint16_t avgEnergy;
};

struct SetTime {
    uint64_t unixMilliseconds;
    int16_t timezoneOffsetMinutes;
};

class TimeAnchor {
public:
    void set(uint64_t unixMilliseconds, uint32_t deviceMilliseconds,
             int16_t timezoneOffsetMinutes) {
        _unixMilliseconds = unixMilliseconds;
        _deviceMilliseconds = deviceMilliseconds;
        _timezoneOffsetMinutes = timezoneOffsetMinutes;
        _valid = true;
    }

    bool resolveUnixSeconds(uint32_t capturedAtMs, uint64_t& unixSeconds) const {
        if (!_valid) return false;
        const int32_t deltaMs = static_cast<int32_t>(capturedAtMs - _deviceMilliseconds);
        const int64_t resolvedMs = static_cast<int64_t>(_unixMilliseconds) + deltaMs;
        if (resolvedMs < 0) return false;
        unixSeconds = static_cast<uint64_t>(resolvedMs) / 1000;
        return true;
    }

    bool isValid() const { return _valid; }
    int16_t timezoneOffsetMinutes() const { return _timezoneOffsetMinutes; }

private:
    uint64_t _unixMilliseconds = 0;
    uint32_t _deviceMilliseconds = 0;
    int16_t _timezoneOffsetMinutes = 0;
    bool _valid = false;
};

struct ControlFrame {
    uint8_t type;
    uint32_t segmentId;
    uint16_t sequence;
    uint64_t unixMilliseconds;
    int16_t timezoneOffsetMinutes;
};

inline size_t encodeSegmentStart(const SegmentStart& frame, uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < SEGMENT_START_SIZE) return 0;
    output[0] = FRAME_SEGMENT_START;
    writeU32(output + 1, frame.segmentId);
    output[5] = frame.protocolVersion;
    writeU32(output + 6, frame.totalLength);
    writeU32(output + 10, frame.durationMs);
    writeU16(output + 14, frame.totalChunks);
    writeU32(output + 16, frame.crc);
    return SEGMENT_START_SIZE;
}

inline bool decodeSegmentStart(const uint8_t* input, size_t length, SegmentStart& frame) {
    if (input == nullptr || length != SEGMENT_START_SIZE || input[0] != FRAME_SEGMENT_START) return false;
    frame.segmentId = readU32(input + 1);
    frame.protocolVersion = input[5];
    frame.totalLength = readU32(input + 6);
    frame.durationMs = readU32(input + 10);
    frame.totalChunks = readU16(input + 14);
    frame.crc = readU32(input + 16);
    return frame.protocolVersion == PROTOCOL_VERSION;
}

inline size_t encodeSegmentMetadata(const SegmentMetadata& frame, uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < SEGMENT_METADATA_SIZE) return 0;
    output[0] = FRAME_SEGMENT_METADATA;
    writeU32(output + 1, frame.segmentId);
    writeU64(output + 5, frame.recordedAtUnixSeconds);
    writeU32(output + 13, frame.silenceBeforeMs);
    writeU16(output + 17, frame.avgEnergy);
    return SEGMENT_METADATA_SIZE;
}

inline size_t encodeSegmentDataHeader(uint32_t segmentId, uint16_t sequence,
                                      uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < SEGMENT_DATA_HEADER_SIZE) return 0;
    output[0] = FRAME_SEGMENT_DATA;
    writeU32(output + 1, segmentId);
    writeU16(output + 5, sequence);
    return SEGMENT_DATA_HEADER_SIZE;
}

inline size_t encodeSetTime(const SetTime& frame, uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < SET_TIME_SIZE) return 0;
    output[0] = FRAME_SET_TIME;
    writeU64(output + 1, frame.unixMilliseconds);
    writeU16(output + 9, static_cast<uint16_t>(frame.timezoneOffsetMinutes));
    return SET_TIME_SIZE;
}

inline size_t encodeDeviceStatus(uint16_t count, uint32_t bytesUsed, uint8_t errorCode,
                                 uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < DEVICE_STATUS_SIZE) return 0;
    output[0] = FRAME_DEVICE_STATUS;
    writeU16(output + 1, count);
    writeU32(output + 3, bytesUsed);
    output[7] = errorCode;
    return DEVICE_STATUS_SIZE;
}

inline bool decodeControlFrame(const uint8_t* input, size_t length, ControlFrame& frame) {
    if (input == nullptr || length == 0) return false;
    frame = {};
    frame.type = input[0];
    switch (frame.type) {
        case FRAME_READY:
            return length == READY_SIZE;
        case FRAME_ACK_WINDOW:
            if (length != ACK_WINDOW_SIZE) return false;
            frame.segmentId = readU32(input + 1);
            frame.sequence = readU16(input + 5);
            return true;
        case FRAME_RESTART_SEGMENT:
        case FRAME_UPLOAD_OK:
            if (length != SEGMENT_COMMAND_SIZE) return false;
            frame.segmentId = readU32(input + 1);
            return true;
        case FRAME_SET_TIME:
            if (length != SET_TIME_SIZE) return false;
            frame.unixMilliseconds = readU64(input + 1);
            frame.timezoneOffsetMinutes = static_cast<int16_t>(readU16(input + 9));
            return true;
        default:
            return false;
    }
}

}  // namespace EchoBleProtocol