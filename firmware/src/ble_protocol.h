#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace EchoBleProtocol {

constexpr uint8_t FRAME_SEGMENT_START = 0x01;
constexpr uint8_t FRAME_SEGMENT_METADATA = 0x02;
constexpr uint8_t FRAME_SEGMENT_DATA = 0x03;
// v3: starts a photo transfer; then SEGMENT_METADATA and SEGMENT_DATA as for audio
constexpr uint8_t FRAME_PHOTO_START = 0x04;
constexpr uint8_t FRAME_READY = 0x10;
constexpr uint8_t FRAME_ACK_WINDOW = 0x11;
constexpr uint8_t FRAME_RESTART_SEGMENT = 0x12;
constexpr uint8_t FRAME_UPLOAD_OK = 0x13;
constexpr uint8_t FRAME_SET_TIME = 0x14;
constexpr uint8_t FRAME_SET_MUTED = 0x15;
constexpr uint8_t FRAME_FORGET_BOND = 0x16;
constexpr uint8_t FRAME_FORGET_BOND_OK = 0x17;
constexpr uint8_t FRAME_TAKE_PHOTO = 0x18;   // v3, app -> wearable
// v4, app -> wearable: [type, image size u32, image SHA-256 x32]; the image follows on
// the OTA characteristic as [offset u32, bytes], in order
constexpr uint8_t FRAME_OTA_BEGIN = 0x19;
constexpr uint8_t FRAME_OTA_ABORT = 0x1A;    // v4, app -> wearable
constexpr uint8_t FRAME_DEVICE_STATUS = 0x20;
constexpr uint8_t FRAME_DEVICE_INFO = 0x21;
constexpr uint8_t FRAME_PHOTO_FAILED = 0x22; // v3, wearable -> app: [type, reason]
// v4, wearable -> app: [type, state, error, bytes received u32]
constexpr uint8_t FRAME_OTA_STATUS = 0x23;
// 3: photos (TAKE_PHOTO, PHOTO_START, PHOTO_FAILED, camera flag in DEVICE_STATUS)
// 4: firmware updates over BLE (OTA_*), DEVICE_INFO sent after READY
// 5: the microSD in DEVICE_STATUS (in use, size, free space, speech waiting on it)
constexpr uint8_t PROTOCOL_VERSION = 5;

constexpr uint8_t PHOTO_FAILED_MUTED = 1;
constexpr uint8_t PHOTO_FAILED_CAPTURE = 2;
constexpr uint8_t PHOTO_FAILED_BUSY = 3;
constexpr uint8_t PHOTO_FAILED_NO_CAMERA = 4;
constexpr uint8_t OTA_STATE_RECEIVING = 1;  // ready for the bytes from `received` on
constexpr uint8_t OTA_STATE_DONE = 2;       // complete and checked: restarting into it
constexpr uint8_t OTA_STATE_FAILED = 3;

constexpr uint8_t OTA_ERROR_NONE = 0;
constexpr uint8_t OTA_ERROR_BUSY = 1;           // audio or a photo still to send
constexpr uint8_t OTA_ERROR_TOO_LARGE = 2;
constexpr uint8_t OTA_ERROR_LOW_BATTERY = 3;
constexpr uint8_t OTA_ERROR_FLASH = 4;
constexpr uint8_t OTA_ERROR_OUT_OF_ORDER = 5;
constexpr uint8_t OTA_ERROR_HASH_MISMATCH = 6;
constexpr uint8_t OTA_ERROR_INVALID_IMAGE = 7;  // not an image this chip can boot
constexpr uint8_t OTA_ERROR_NOT_STARTED = 8;
constexpr uint8_t OTA_ERROR_TIMEOUT = 9;

constexpr size_t SHA256_SIZE = 32;

// Photo transfers use ids with the high bit set, apart from audio segment ids
constexpr uint32_t PHOTO_SEGMENT_ID_FLAG = 0x80000000U;

constexpr size_t SEGMENT_START_SIZE = 20;
constexpr size_t SEGMENT_METADATA_SIZE = 19;
constexpr size_t SEGMENT_DATA_HEADER_SIZE = 7;
constexpr size_t READY_SIZE = 1;
constexpr size_t ACK_WINDOW_SIZE = 7;
constexpr size_t SEGMENT_COMMAND_SIZE = 5;
constexpr size_t SET_TIME_SIZE = 11;
constexpr size_t SET_MUTED_SIZE = 2;
constexpr size_t FORGET_BOND_SIZE = 1;
constexpr size_t FORGET_BOND_OK_SIZE = 1;
constexpr size_t TAKE_PHOTO_SIZE = 1;
constexpr size_t PHOTO_FAILED_SIZE = 2;
constexpr size_t DEVICE_STATUS_SIZE = 26;
constexpr size_t DEVICE_INFO_SIZE = 5;
constexpr size_t OTA_BEGIN_SIZE = 1 + 4 + SHA256_SIZE;
constexpr size_t OTA_ABORT_SIZE = 1;
constexpr size_t OTA_STATUS_SIZE = 7;
constexpr size_t OTA_DATA_HEADER_SIZE = 4;
constexpr size_t MAX_CONTROL_FRAME_SIZE = OTA_BEGIN_SIZE;
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

struct DeviceStatus {
    bool muted;
    bool overflowed;
    uint8_t batteryPercent;
    uint16_t bufferCount;
    uint32_t bufferBytes;
    uint32_t droppedSegments;
    bool cameraAvailable;  // v3; left out of an initializer it is false
    // v5: the microSD, when one is in use (sizes in MB, its speech in KB)
    bool cardInUse;
    uint32_t cardTotalMb;
    uint32_t cardFreeMb;
    uint32_t cardPendingKb;
};

struct DeviceInfo {
    uint8_t protocolVersion;
    uint8_t firmwareMajor;
    uint8_t firmwareMinor;
    uint8_t firmwarePatch;
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
    bool muted;
    uint32_t otaSize;
    uint8_t otaSha256[SHA256_SIZE];
};

inline size_t encodeSegmentStart(const SegmentStart& frame, uint8_t* output, size_t capacity,
                                 uint8_t frameType = FRAME_SEGMENT_START) {
    if (output == nullptr || capacity < SEGMENT_START_SIZE) return 0;
    if (frameType != FRAME_SEGMENT_START && frameType != FRAME_PHOTO_START) return 0;
    output[0] = frameType;
    writeU32(output + 1, frame.segmentId);
    output[5] = frame.protocolVersion;
    writeU32(output + 6, frame.totalLength);
    writeU32(output + 10, frame.durationMs);
    writeU16(output + 14, frame.totalChunks);
    writeU32(output + 16, frame.crc);
    return SEGMENT_START_SIZE;
}

inline bool decodeSegmentStart(const uint8_t* input, size_t length, SegmentStart& frame) {
    if (input == nullptr || length != SEGMENT_START_SIZE ||
        (input[0] != FRAME_SEGMENT_START && input[0] != FRAME_PHOTO_START)) return false;
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

inline bool isValidBatteryPercent(uint8_t batteryPercent) {
    return batteryPercent <= 100 || batteryPercent == 255;
}

inline size_t encodeDeviceStatusV2(const DeviceStatus& status,
                                   uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < DEVICE_STATUS_SIZE ||
        !isValidBatteryPercent(status.batteryPercent)) return 0;
    output[0] = FRAME_DEVICE_STATUS;
    output[1] = PROTOCOL_VERSION;
    output[2] = static_cast<uint8_t>((status.muted ? 0x01 : 0x00) |
                                     (status.overflowed ? 0x02 : 0x00) |
                                     (status.cameraAvailable ? 0x04 : 0x00) |
                                     (status.cardInUse ? 0x08 : 0x00));
    output[3] = status.batteryPercent;
    writeU16(output + 4, status.bufferCount);
    writeU32(output + 6, status.bufferBytes);
    writeU32(output + 10, status.droppedSegments);
    writeU32(output + 14, status.cardTotalMb);
    writeU32(output + 18, status.cardFreeMb);
    writeU32(output + 22, status.cardPendingKb);
    return DEVICE_STATUS_SIZE;
}

inline size_t encodeDeviceStatusV2(bool muted, bool overflowed, uint8_t batteryPercent,
                                   uint16_t bufferCount, uint32_t bufferBytes,
                                   uint32_t droppedSegments,
                                   uint8_t* output, size_t capacity) {
    DeviceStatus status = {};
    status.muted = muted;
    status.overflowed = overflowed;
    status.batteryPercent = batteryPercent;
    status.bufferCount = bufferCount;
    status.bufferBytes = bufferBytes;
    status.droppedSegments = droppedSegments;
    return encodeDeviceStatusV2(status, output, capacity);
}

inline bool decodeDeviceStatusV2(const uint8_t* input, size_t length, DeviceStatus& status) {
    if (input == nullptr || length != DEVICE_STATUS_SIZE ||
        input[0] != FRAME_DEVICE_STATUS || input[1] != PROTOCOL_VERSION ||
        (input[2] & 0xF0) != 0 || !isValidBatteryPercent(input[3])) return false;
    status.muted = (input[2] & 0x01) != 0;
    status.overflowed = (input[2] & 0x02) != 0;
    status.cameraAvailable = (input[2] & 0x04) != 0;
    status.batteryPercent = input[3];
    status.bufferCount = readU16(input + 4);
    status.bufferBytes = readU32(input + 6);
    status.droppedSegments = readU32(input + 10);
    status.cardInUse = (input[2] & 0x08) != 0;
    status.cardTotalMb = readU32(input + 14);
    status.cardFreeMb = readU32(input + 18);
    status.cardPendingKb = readU32(input + 22);
    return true;
}

inline size_t encodeDeviceInfo(const DeviceInfo& info, uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < DEVICE_INFO_SIZE ||
        info.protocolVersion != PROTOCOL_VERSION) return 0;
    output[0] = FRAME_DEVICE_INFO;
    output[1] = info.protocolVersion;
    output[2] = info.firmwareMajor;
    output[3] = info.firmwareMinor;
    output[4] = info.firmwarePatch;
    return DEVICE_INFO_SIZE;
}

inline bool decodeDeviceInfo(const uint8_t* input, size_t length, DeviceInfo& info) {
    if (input == nullptr || length != DEVICE_INFO_SIZE ||
        input[0] != FRAME_DEVICE_INFO || input[1] != PROTOCOL_VERSION) return false;
    info.protocolVersion = input[1];
    info.firmwareMajor = input[2];
    info.firmwareMinor = input[3];
    info.firmwarePatch = input[4];
    return true;
}

inline size_t encodePhotoFailed(uint8_t reason, uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < PHOTO_FAILED_SIZE ||
        reason < PHOTO_FAILED_MUTED || reason > PHOTO_FAILED_NO_CAMERA) return 0;
    output[0] = FRAME_PHOTO_FAILED;
    output[1] = reason;
    return PHOTO_FAILED_SIZE;
}

inline size_t encodeOtaStatus(uint8_t state, uint8_t error, uint32_t received,
                              uint8_t* output, size_t capacity) {
    if (output == nullptr || capacity < OTA_STATUS_SIZE ||
        state < OTA_STATE_RECEIVING || state > OTA_STATE_FAILED) return 0;
    output[0] = FRAME_OTA_STATUS;
    output[1] = state;
    output[2] = error;
    writeU32(output + 3, received);
    return OTA_STATUS_SIZE;
}

/** A chunk of a firmware image: [offset u32, bytes]; false without any bytes. */
inline bool decodeOtaData(const uint8_t* input, size_t length, uint32_t& offset,
                          const uint8_t*& data, size_t& dataLength) {
    if (input == nullptr || length <= OTA_DATA_HEADER_SIZE) return false;
    offset = readU32(input);
    data = input + OTA_DATA_HEADER_SIZE;
    dataLength = length - OTA_DATA_HEADER_SIZE;
    return true;
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
        case FRAME_SET_MUTED:
            if (length != SET_MUTED_SIZE || input[1] > 1) return false;
            frame.muted = input[1] == 1;
            return true;
        case FRAME_FORGET_BOND:
            return length == FORGET_BOND_SIZE;
        case FRAME_TAKE_PHOTO:
            return length == TAKE_PHOTO_SIZE;
        case FRAME_OTA_BEGIN:
            if (length != OTA_BEGIN_SIZE) return false;
            frame.otaSize = readU32(input + 1);
            memcpy(frame.otaSha256, input + 5, SHA256_SIZE);
            return true;
        case FRAME_OTA_ABORT:
            return length == OTA_ABORT_SIZE;
        default:
            return false;
    }
}

}  // namespace EchoBleProtocol