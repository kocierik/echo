#include <unity.h>

#include <cstdint>
#include <cstring>

#include "ble_protocol.h"
#include "buffered_segment.h"

using namespace EchoBleProtocol;

void test_crc32_known_vector() {
    const uint8_t bytes[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
    TEST_ASSERT_EQUAL_HEX32(0xCBF43926U, crc32(bytes, sizeof(bytes)));
}

void test_incremental_crc32_matches_one_shot_crc32() {
    const uint8_t bytes[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
    uint32_t crc = CRC32_INITIAL_VALUE;
    crc = crc32Update(crc, bytes, 4);
    crc = crc32Update(crc, bytes + 4, sizeof(bytes) - 4);

    TEST_ASSERT_EQUAL_HEX32(crc32(bytes, sizeof(bytes)), crc32Finalize(crc));
}

void test_buffered_segment_header_round_trips_stored_crc() {
    const BufferedSegment header = {
        0x78563412U, 4096U, 6000U, 800U, 123456U, 321U, 0xCBF43926U};
    uint8_t encoded[BufferedSegmentCodec::HEADER_SIZE] = {};

    BufferedSegmentCodec::encode(header, encoded);
    const BufferedSegment decoded = BufferedSegmentCodec::decode(encoded);

    TEST_ASSERT_EQUAL_UINT32(26, BufferedSegmentCodec::HEADER_SIZE);
    TEST_ASSERT_EQUAL_HEX32(header.segmentId, decoded.segmentId);
    TEST_ASSERT_EQUAL_UINT32(header.dataLength, decoded.dataLength);
    TEST_ASSERT_EQUAL_UINT32(header.durationMs, decoded.durationMs);
    TEST_ASSERT_EQUAL_UINT32(header.silenceBeforeMs, decoded.silenceBeforeMs);
    TEST_ASSERT_EQUAL_UINT32(header.capturedAtMs, decoded.capturedAtMs);
    TEST_ASSERT_EQUAL_UINT16(header.avgEnergy, decoded.avgEnergy);
    TEST_ASSERT_EQUAL_HEX32(header.crc, decoded.crc);
}

void test_buffered_segment_header_exact_bytes() {
    const BufferedSegment header = {
        0x04030201U, 0x08070605U, 0x0C0B0A09U, 0x100F0E0DU,
        0x14131211U, 0x1615U, 0x1A191817U};
    const uint8_t expected[26] = {
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A};
    uint8_t encoded[BufferedSegmentCodec::HEADER_SIZE] = {};

    BufferedSegmentCodec::encode(header, encoded);

    TEST_ASSERT_EQUAL_UINT32(sizeof(expected), BufferedSegmentCodec::HEADER_SIZE);
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, encoded, sizeof(expected));
}

void test_buffered_segment_header_round_trips_the_unix_time_flag() {
    BufferedSegment header = {7U, 4096U, 25000U, 800U, 1762800000U, 321U, 0xCBF43926U};
    header.unixTime = true;
    uint8_t encoded[BufferedSegmentCodec::HEADER_SIZE] = {};

    BufferedSegmentCodec::encode(header, encoded);
    BufferedSegment decoded = BufferedSegmentCodec::decode(encoded);

    TEST_ASSERT_TRUE(decoded.unixTime);
    TEST_ASSERT_EQUAL_UINT32(25000U, decoded.durationMs);  // the flag stays out of it
    TEST_ASSERT_EQUAL_UINT32(1762800000U, decoded.capturedAtMs);
    TEST_ASSERT_EQUAL_HEX32(0x80000000U | 25000U, readU32(encoded + 8));

    header.unixTime = false;
    BufferedSegmentCodec::encode(header, encoded);
    decoded = BufferedSegmentCodec::decode(encoded);
    TEST_ASSERT_FALSE(decoded.unixTime);
    TEST_ASSERT_EQUAL_UINT32(25000U, decoded.durationMs);
    TEST_ASSERT_EQUAL_HEX32(25000U, readU32(encoded + 8));
}

void test_a_legacy_header_decodes_as_boot_relative() {
    // Written before the flag existed: the top bit of durationMs is clear
    uint8_t encoded[BufferedSegmentCodec::HEADER_SIZE] = {};
    writeU32(encoded, 9U);
    writeU32(encoded + 4, 100U);
    writeU32(encoded + 8, 0x7FFFFFFFU);
    writeU32(encoded + 12, 0U);
    writeU32(encoded + 16, 123456U);
    writeU16(encoded + 20, 5U);
    writeU32(encoded + 22, 0xDEADBEEFU);

    const BufferedSegment decoded = BufferedSegmentCodec::decode(encoded);

    TEST_ASSERT_FALSE(decoded.unixTime);
    TEST_ASSERT_EQUAL_HEX32(0x7FFFFFFFU, decoded.durationMs);
    TEST_ASSERT_EQUAL_UINT32(123456U, decoded.capturedAtMs);
    TEST_ASSERT_EQUAL_HEX32(0xDEADBEEFU, decoded.crc);
}

void test_recorded_at_of_a_boot_relative_segment_uses_the_anchor() {
    TimeAnchor anchor;
    anchor.set(1700000000500ULL, 1000U, 0);
    BufferedSegment segment = {1U, 10U, 1000U, 0U, 1500U, 0U, 0U};
    uint64_t unixSeconds = 0;

    TEST_ASSERT_TRUE(resolveRecordedAt(segment, anchor, 99999U, unixSeconds));
    TEST_ASSERT_EQUAL_UINT64(1700000001ULL, unixSeconds);

    TimeAnchor unset;
    TEST_ASSERT_FALSE(resolveRecordedAt(segment, unset, 99999U, unixSeconds));
}

void test_recorded_at_of_a_unix_segment_is_its_own_time() {
    TimeAnchor unset;  // a record from an earlier boot needs no anchor
    BufferedSegment segment = {1U, 10U, 1000U, 0U, 1762800000U, 0U, 0U};
    segment.unixTime = true;
    uint64_t unixSeconds = 0;

    TEST_ASSERT_TRUE(resolveRecordedAt(segment, unset, 5000U, unixSeconds));
    TEST_ASSERT_EQUAL_UINT64(1762800000ULL, unixSeconds);
}

void test_recorded_at_of_an_unknown_time_segment_is_the_delivery_time() {
    TimeAnchor anchor;
    anchor.set(1700000000000ULL, 1000U, 0);
    BufferedSegment segment = {1U, 10U, 1000U, 0U, 0U, 0U, 0U};
    segment.unixTime = true;
    uint64_t unixSeconds = 0;

    TEST_ASSERT_TRUE(resolveRecordedAt(segment, anchor, 61000U, unixSeconds));
    TEST_ASSERT_EQUAL_UINT64(1700000060ULL, unixSeconds);

    TimeAnchor unset;
    TEST_ASSERT_FALSE(resolveRecordedAt(segment, unset, 61000U, unixSeconds));
}

void test_little_endian_round_trips() {
    uint8_t bytes[8] = {};
    writeU16(bytes, 0xABCDU);
    TEST_ASSERT_EQUAL_HEX16(0xABCDU, readU16(bytes));
    writeU32(bytes, 0x89ABCDEFU);
    TEST_ASSERT_EQUAL_HEX32(0x89ABCDEFU, readU32(bytes));
    writeU64(bytes, 0x0123456789ABCDEFULL);
    TEST_ASSERT_EQUAL_HEX64(0x0123456789ABCDEFULL, readU64(bytes));
}

void test_segment_start_exact_bytes() {
    const SegmentStart frame = {
        0x78563412U, PROTOCOL_VERSION, 0x44332211U, 0x88776655U, 0xAA99U, 0xDDCCBBAAU};
    const uint8_t expected[] = {
        0x01, 0x12, 0x34, 0x56, 0x78, 0x06, 0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xAA, 0xBB, 0xCC, 0xDD};
    uint8_t encoded[SEGMENT_START_SIZE] = {};

    TEST_ASSERT_EQUAL_UINT32(SEGMENT_START_SIZE, encodeSegmentStart(frame, encoded, sizeof(encoded)));
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, encoded, sizeof(expected));

    SegmentStart decoded = {};
    TEST_ASSERT_TRUE(decodeSegmentStart(encoded, sizeof(encoded), decoded));
    TEST_ASSERT_EQUAL_HEX32(frame.segmentId, decoded.segmentId);
    TEST_ASSERT_EQUAL_HEX32(frame.crc, decoded.crc);
}

void test_device_status_v2_exact_bytes_and_round_trips() {
    uint8_t bytes[DEVICE_STATUS_SIZE] = {};
    TEST_ASSERT_EQUAL_UINT32(26, encodeDeviceStatusV2(
        true, true, 255, 3, 12000, 7, bytes, sizeof(bytes)));
    // No card: its fields are zero
    const uint8_t expected[] = {
        0x20, 0x06, 0x03, 0xFF, 0x03, 0x00,
        0xE0, 0x2E, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, bytes, sizeof(expected));

    DeviceStatus decoded = {};
    TEST_ASSERT_TRUE(decodeDeviceStatusV2(bytes, sizeof(bytes), decoded));
    TEST_ASSERT_TRUE(decoded.muted);
    TEST_ASSERT_TRUE(decoded.overflowed);
    TEST_ASSERT_EQUAL_UINT8(255, decoded.batteryPercent);
    TEST_ASSERT_EQUAL_UINT16(3, decoded.bufferCount);
    TEST_ASSERT_EQUAL_UINT32(12000, decoded.bufferBytes);
    TEST_ASSERT_EQUAL_UINT32(7, decoded.droppedSegments);
}

void test_device_status_says_whether_a_card_is_in_use_its_room_and_its_speech() {
    DeviceStatus status = {};
    status.batteryPercent = 80;
    status.cardInUse = true;
    status.cardTotalMb = 30436;
    status.cardFreeMb = 29802;
    status.cardPendingKb = 5120;
    uint8_t bytes[DEVICE_STATUS_SIZE] = {};

    TEST_ASSERT_EQUAL_UINT32(26, encodeDeviceStatusV2(status, bytes, sizeof(bytes)));
    TEST_ASSERT_EQUAL_HEX8(0x08, bytes[2]);
    const uint8_t card[] = {0xE4, 0x76, 0x00, 0x00, 0x6A, 0x74, 0x00, 0x00,
                            0x00, 0x14, 0x00, 0x00};
    TEST_ASSERT_EQUAL_UINT8_ARRAY(card, bytes + 14, sizeof(card));

    DeviceStatus decoded = {};
    TEST_ASSERT_TRUE(decodeDeviceStatusV2(bytes, sizeof(bytes), decoded));
    TEST_ASSERT_TRUE(decoded.cardInUse);
    TEST_ASSERT_EQUAL_UINT32(30436, decoded.cardTotalMb);
    TEST_ASSERT_EQUAL_UINT32(29802, decoded.cardFreeMb);
    TEST_ASSERT_EQUAL_UINT32(5120, decoded.cardPendingKb);
}

void test_device_info_exact_bytes_and_round_trips() {
    const DeviceInfo info = {PROTOCOL_VERSION, 1, 2, 3};
    const uint8_t expected[] = {0x21, 0x06, 0x01, 0x02, 0x03};
    uint8_t bytes[DEVICE_INFO_SIZE] = {};

    TEST_ASSERT_EQUAL_UINT32(
        DEVICE_INFO_SIZE, encodeDeviceInfo(info, bytes, sizeof(bytes)));
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, bytes, sizeof(expected));

    DeviceInfo decoded = {};
    TEST_ASSERT_TRUE(decodeDeviceInfo(bytes, sizeof(bytes), decoded));
    TEST_ASSERT_EQUAL_UINT8(PROTOCOL_VERSION, decoded.protocolVersion);
    TEST_ASSERT_EQUAL_UINT8(1, decoded.firmwareMajor);
    TEST_ASSERT_EQUAL_UINT8(2, decoded.firmwareMinor);
    TEST_ASSERT_EQUAL_UINT8(3, decoded.firmwarePatch);
}

void test_status_and_info_reject_malformed_frames() {
    const uint8_t validStatus[] = {
        0x20, 0x05, 0x00, 0x64, 0x01, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    uint8_t malformedStatus[DEVICE_STATUS_SIZE] = {};
    DeviceStatus status = {};

    std::memcpy(malformedStatus, validStatus, sizeof(validStatus));
    malformedStatus[0] = FRAME_DEVICE_INFO;
    TEST_ASSERT_FALSE(decodeDeviceStatusV2(malformedStatus, sizeof(malformedStatus), status));
    std::memcpy(malformedStatus, validStatus, sizeof(validStatus));
    malformedStatus[1] = 1;
    TEST_ASSERT_FALSE(decodeDeviceStatusV2(malformedStatus, sizeof(malformedStatus), status));
    std::memcpy(malformedStatus, validStatus, sizeof(validStatus));
    malformedStatus[2] = 0x10;
    TEST_ASSERT_FALSE(decodeDeviceStatusV2(malformedStatus, sizeof(malformedStatus), status));
    std::memcpy(malformedStatus, validStatus, sizeof(validStatus));
    malformedStatus[3] = 101;
    TEST_ASSERT_FALSE(decodeDeviceStatusV2(malformedStatus, sizeof(malformedStatus), status));
    TEST_ASSERT_FALSE(decodeDeviceStatusV2(validStatus, sizeof(validStatus) - 1, status));

    const uint8_t validInfo[] = {FRAME_DEVICE_INFO, PROTOCOL_VERSION, 1, 2, 3};
    uint8_t malformedInfo[DEVICE_INFO_SIZE] = {};
    DeviceInfo info = {};
    std::memcpy(malformedInfo, validInfo, sizeof(validInfo));
    malformedInfo[0] = FRAME_DEVICE_STATUS;
    TEST_ASSERT_FALSE(decodeDeviceInfo(malformedInfo, sizeof(malformedInfo), info));
    std::memcpy(malformedInfo, validInfo, sizeof(validInfo));
    malformedInfo[1] = 1;
    TEST_ASSERT_FALSE(decodeDeviceInfo(malformedInfo, sizeof(malformedInfo), info));
    TEST_ASSERT_FALSE(decodeDeviceInfo(validInfo, sizeof(validInfo) - 1, info));
}

void test_status_and_info_encoders_reject_invalid_values_and_short_buffers() {
    uint8_t statusBytes[DEVICE_STATUS_SIZE] = {};
    TEST_ASSERT_EQUAL_UINT32(0, encodeDeviceStatusV2(
        false, false, 101, 0, 0, 0, statusBytes, sizeof(statusBytes)));
    TEST_ASSERT_EQUAL_UINT32(0, encodeDeviceStatusV2(
        false, false, 255, 0, 0, 0, statusBytes, sizeof(statusBytes) - 1));

    const DeviceInfo info = {PROTOCOL_VERSION, 1, 2, 3};
    uint8_t infoBytes[DEVICE_INFO_SIZE] = {};
    TEST_ASSERT_EQUAL_UINT32(
        0, encodeDeviceInfo(info, infoBytes, sizeof(infoBytes) - 1));
}

void test_mic_gain_frame_takes_1_to_8() {
    const uint8_t five[] = {FRAME_SET_MIC_GAIN, 5};
    const uint8_t zero[] = {FRAME_SET_MIC_GAIN, 0};
    const uint8_t nine[] = {FRAME_SET_MIC_GAIN, MAX_MIC_GAIN + 1};
    const uint8_t shortGain[] = {FRAME_SET_MIC_GAIN};
    ControlFrame decoded = {};

    TEST_ASSERT_TRUE(decodeControlFrame(five, sizeof(five), decoded));
    TEST_ASSERT_EQUAL_UINT8(5, decoded.micGain);
    TEST_ASSERT_FALSE(decodeControlFrame(zero, sizeof(zero), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(nine, sizeof(nine), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(shortGain, sizeof(shortGain), decoded));
}

void test_power_off_frame_turns_off_or_cancels() {
    const uint8_t off[] = {FRAME_POWER_OFF, 1};
    const uint8_t cancel[] = {FRAME_POWER_OFF, 0};
    const uint8_t invalid[] = {FRAME_POWER_OFF, 2};
    const uint8_t shortFrame[] = {FRAME_POWER_OFF};
    const uint8_t longFrame[] = {FRAME_POWER_OFF, 1, 0};
    ControlFrame decoded = {};

    TEST_ASSERT_EQUAL_HEX8(0x1C, FRAME_POWER_OFF);
    TEST_ASSERT_TRUE(decodeControlFrame(off, sizeof(off), decoded));
    TEST_ASSERT_EQUAL_UINT8(FRAME_POWER_OFF, decoded.type);
    TEST_ASSERT_TRUE(decoded.turnOff);
    TEST_ASSERT_TRUE(decodeControlFrame(cancel, sizeof(cancel), decoded));
    TEST_ASSERT_FALSE(decoded.turnOff);
    TEST_ASSERT_FALSE(decodeControlFrame(invalid, sizeof(invalid), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(shortFrame, sizeof(shortFrame), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(longFrame, sizeof(longFrame), decoded));
}

void test_power_state_exact_bytes_and_protocol_unchanged() {
    uint8_t frame[POWER_STATE_SIZE] = {};
    TEST_ASSERT_EQUAL_UINT32(POWER_STATE_SIZE,
        encodePowerState(POWER_STATE_REFUSED, POWER_REASON_UPDATING, frame, sizeof(frame)));
    const uint8_t refused[] = {0x24, 3, 1};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(refused, frame, sizeof(refused));

    TEST_ASSERT_EQUAL_UINT32(POWER_STATE_SIZE,
        encodePowerState(POWER_STATE_ON, POWER_REASON_NONE, frame, sizeof(frame)));
    const uint8_t on[] = {0x24, 0, 0};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(on, frame, sizeof(on));

    TEST_ASSERT_EQUAL_UINT32(0, encodePowerState(POWER_STATE_REFUSED + 1, 0, frame, sizeof(frame)));
    TEST_ASSERT_EQUAL_UINT32(0, encodePowerState(POWER_STATE_OFF, 0, frame, POWER_STATE_SIZE - 1));
    TEST_ASSERT_EQUAL_UINT32(0, encodePowerState(POWER_STATE_OFF, 0, nullptr, POWER_STATE_SIZE));
    // New frames are gated on the firmware version, as SET_MIC_GAIN: no protocol bump
    TEST_ASSERT_EQUAL_UINT8(6, PROTOCOL_VERSION);
}

void test_privacy_control_frames_decode_exact_lengths_and_values() {
    const uint8_t muted[] = {FRAME_SET_MUTED, 1};
    const uint8_t listening[] = {FRAME_SET_MUTED, 0};
    const uint8_t invalidMute[] = {FRAME_SET_MUTED, 2};
    const uint8_t shortMute[] = {FRAME_SET_MUTED};
    const uint8_t forget[] = {FRAME_FORGET_BOND};
    const uint8_t longForget[] = {FRAME_FORGET_BOND, 0};
    const uint8_t forgetOk[] = {FRAME_FORGET_BOND_OK};
    ControlFrame decoded = {};

    TEST_ASSERT_TRUE(decodeControlFrame(muted, sizeof(muted), decoded));
    TEST_ASSERT_TRUE(decoded.muted);
    TEST_ASSERT_TRUE(decodeControlFrame(listening, sizeof(listening), decoded));
    TEST_ASSERT_FALSE(decoded.muted);
    TEST_ASSERT_FALSE(decodeControlFrame(invalidMute, sizeof(invalidMute), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(shortMute, sizeof(shortMute), decoded));
    TEST_ASSERT_TRUE(decodeControlFrame(forget, sizeof(forget), decoded));
    TEST_ASSERT_EQUAL_UINT8(FRAME_FORGET_BOND, decoded.type);
    TEST_ASSERT_EQUAL_UINT32(FORGET_BOND_OK_SIZE, sizeof(forgetOk));
    TEST_ASSERT_FALSE(decodeControlFrame(longForget, sizeof(longForget), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(forgetOk, sizeof(forgetOk), decoded));
}

void test_set_time_exact_bytes() {
    const SetTime frame = {0x0102030405060708ULL, -330};
    const uint8_t expected[] = {
        0x14, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0xB6, 0xFE};
    uint8_t encoded[SET_TIME_SIZE] = {};

    TEST_ASSERT_EQUAL_UINT32(SET_TIME_SIZE, encodeSetTime(frame, encoded, sizeof(encoded)));
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, encoded, sizeof(expected));

    ControlFrame decoded = {};
    TEST_ASSERT_TRUE(decodeControlFrame(encoded, sizeof(encoded), decoded));
    TEST_ASSERT_EQUAL_UINT8(FRAME_SET_TIME, decoded.type);
    TEST_ASSERT_EQUAL_UINT64(frame.unixMilliseconds, decoded.unixMilliseconds);
    TEST_ASSERT_EQUAL_INT16(frame.timezoneOffsetMinutes, decoded.timezoneOffsetMinutes);
}

void test_control_frames_reject_truncation_and_unknown_types() {
    const uint8_t truncatedAck[] = {FRAME_ACK_WINDOW, 1, 0, 0, 0, 2};
    const uint8_t truncatedTime[] = {FRAME_SET_TIME, 1, 2, 3};
    const uint8_t unknown[] = {0x7F};
    ControlFrame decoded = {};

    TEST_ASSERT_FALSE(decodeControlFrame(truncatedAck, sizeof(truncatedAck), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(truncatedTime, sizeof(truncatedTime), decoded));
    TEST_ASSERT_FALSE(decodeControlFrame(unknown, sizeof(unknown), decoded));
}

void test_notification_payload_is_capped_by_att_and_characteristic_limits() {
    TEST_ASSERT_EQUAL_UINT32(20, notificationValueSizeForMtu(23));
    TEST_ASSERT_EQUAL_UINT32(512, notificationValueSizeForMtu(517));
    TEST_ASSERT_EQUAL_UINT32(512, notificationValueSizeForMtu(UINT16_MAX));
    TEST_ASSERT_EQUAL_UINT32(100, notificationValueSizeForMtu(517, 100));
    TEST_ASSERT_EQUAL_UINT32(0, notificationValueSizeForMtu(3));

    TEST_ASSERT_EQUAL_UINT32(13, segmentDataPayloadSizeForMtu(23));
    TEST_ASSERT_EQUAL_UINT32(237, segmentDataPayloadSizeForMtu(247));
    TEST_ASSERT_EQUAL_UINT32(505, segmentDataPayloadSizeForMtu(517));
    TEST_ASSERT_EQUAL_UINT32(0, segmentDataPayloadSizeForMtu(10, 7));
}

void test_protocol_encoders_accept_maximum_fields_and_reject_short_buffers() {
    const SegmentStart frame = {
        UINT32_MAX, PROTOCOL_VERSION, UINT32_MAX, UINT32_MAX, UINT16_MAX, UINT32_MAX};
    uint8_t encoded[SEGMENT_START_SIZE] = {};

    TEST_ASSERT_EQUAL_UINT32(0, encodeSegmentStart(frame, encoded, sizeof(encoded) - 1));
    TEST_ASSERT_EQUAL_UINT32(SEGMENT_START_SIZE,
                             encodeSegmentStart(frame, encoded, sizeof(encoded)));

    SegmentStart decoded = {};
    TEST_ASSERT_TRUE(decodeSegmentStart(encoded, sizeof(encoded), decoded));
    TEST_ASSERT_EQUAL_UINT32(UINT32_MAX, decoded.segmentId);
    TEST_ASSERT_EQUAL_UINT32(UINT32_MAX, decoded.totalLength);
    TEST_ASSERT_EQUAL_UINT32(UINT32_MAX, decoded.durationMs);
    TEST_ASSERT_EQUAL_UINT16(UINT16_MAX, decoded.totalChunks);
    TEST_ASSERT_EQUAL_UINT32(UINT32_MAX, decoded.crc);

    uint8_t dataHeader[SEGMENT_DATA_HEADER_SIZE] = {};
    TEST_ASSERT_EQUAL_UINT32(0, encodeSegmentDataHeader(
        UINT32_MAX, UINT16_MAX, dataHeader, sizeof(dataHeader) - 1));
    TEST_ASSERT_EQUAL_UINT32(SEGMENT_DATA_HEADER_SIZE, encodeSegmentDataHeader(
        UINT32_MAX, UINT16_MAX, dataHeader, sizeof(dataHeader)));
    TEST_ASSERT_EQUAL_UINT32(UINT32_MAX, readU32(dataHeader + 1));
    TEST_ASSERT_EQUAL_UINT16(UINT16_MAX, readU16(dataHeader + 5));
}

void test_time_anchor_resolves_captures_before_and_after_set_time() {
    TimeAnchor anchor;
    anchor.set(1700000000500ULL, 1000U, -60);
    uint64_t unixSeconds = 0;

    TEST_ASSERT_TRUE(anchor.resolveUnixSeconds(500U, unixSeconds));
    TEST_ASSERT_EQUAL_UINT64(1700000000ULL, unixSeconds);
    TEST_ASSERT_TRUE(anchor.resolveUnixSeconds(1500U, unixSeconds));
    TEST_ASSERT_EQUAL_UINT64(1700000001ULL, unixSeconds);
    TEST_ASSERT_EQUAL_INT16(-60, anchor.timezoneOffsetMinutes());
}

void test_time_anchor_uses_wrap_safe_millis_delta() {
    TimeAnchor anchor;
    anchor.set(100000ULL, 0x00000020U, 0);
    uint64_t unixSeconds = 0;

    TEST_ASSERT_TRUE(anchor.resolveUnixSeconds(0xFFFFFFF0U, unixSeconds));
    TEST_ASSERT_EQUAL_UINT64(99ULL, unixSeconds);
}

void test_status_frames_still_decode_with_the_valid_status() {
    const uint8_t validStatus[] = {
        0x20, 0x06, 0x04, 0x64, 0x01, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    DeviceStatus status = {};
    TEST_ASSERT_TRUE(decodeDeviceStatusV2(validStatus, sizeof(validStatus), status));
    TEST_ASSERT_TRUE(status.cameraAvailable);
    TEST_ASSERT_FALSE(status.muted);
}

void test_camera_flag_is_bit_two_of_the_status() {
    DeviceStatus status = {false, false, 50, 0, 0, 0};
    uint8_t bytes[DEVICE_STATUS_SIZE] = {};
    encodeDeviceStatusV2(status, bytes, sizeof(bytes));
    TEST_ASSERT_EQUAL_HEX8(0x00, bytes[2]);
    status.cameraAvailable = true;
    encodeDeviceStatusV2(status, bytes, sizeof(bytes));
    TEST_ASSERT_EQUAL_HEX8(0x04, bytes[2]);
}

void test_photo_start_has_the_segment_start_layout_with_its_own_type() {
    const SegmentStart frame = {
        PHOTO_SEGMENT_ID_FLAG | 7U, PROTOCOL_VERSION, 90000U, 0U, 380U, 0x12345678U};
    uint8_t encoded[SEGMENT_START_SIZE] = {};

    TEST_ASSERT_EQUAL_UINT32(SEGMENT_START_SIZE,
        encodeSegmentStart(frame, encoded, sizeof(encoded), FRAME_PHOTO_START));
    TEST_ASSERT_EQUAL_HEX8(FRAME_PHOTO_START, encoded[0]);
    SegmentStart decoded = {};
    TEST_ASSERT_TRUE(decodeSegmentStart(encoded, sizeof(encoded), decoded));
    TEST_ASSERT_EQUAL_HEX32(frame.segmentId, decoded.segmentId);
    TEST_ASSERT_EQUAL_UINT32(90000U, decoded.totalLength);
    // Only the two start types
    TEST_ASSERT_EQUAL_UINT32(0, encodeSegmentStart(frame, encoded, sizeof(encoded), FRAME_SEGMENT_DATA));
}

void test_take_photo_and_photo_failed_frames() {
    const uint8_t take[] = {FRAME_TAKE_PHOTO};
    const uint8_t takeTooLong[] = {FRAME_TAKE_PHOTO, 0};
    ControlFrame frame = {};
    TEST_ASSERT_TRUE(decodeControlFrame(take, sizeof(take), frame));
    TEST_ASSERT_EQUAL_HEX8(FRAME_TAKE_PHOTO, frame.type);
    TEST_ASSERT_FALSE(decodeControlFrame(takeTooLong, sizeof(takeTooLong), frame));

    uint8_t failed[PHOTO_FAILED_SIZE] = {};
    TEST_ASSERT_EQUAL_UINT32(PHOTO_FAILED_SIZE, encodePhotoFailed(PHOTO_FAILED_BUSY, failed, sizeof(failed)));
    TEST_ASSERT_EQUAL_HEX8(FRAME_PHOTO_FAILED, failed[0]);
    TEST_ASSERT_EQUAL_UINT8(PHOTO_FAILED_BUSY, failed[1]);
    TEST_ASSERT_EQUAL_UINT32(0, encodePhotoFailed(0, failed, sizeof(failed)));
    TEST_ASSERT_EQUAL_UINT32(0, encodePhotoFailed(PHOTO_FAILED_NO_CAMERA + 1, failed, sizeof(failed)));
    TEST_ASSERT_EQUAL_UINT32(0, encodePhotoFailed(PHOTO_FAILED_MUTED, failed, 1));
}

void test_ota_frames() {
    uint8_t begin[OTA_BEGIN_SIZE] = {FRAME_OTA_BEGIN, 0x00, 0x10, 0x09, 0x00};
    for (size_t index = 0; index < SHA256_SIZE + OTA_SIGNATURE_SIZE; ++index) {
        begin[5 + index] = static_cast<uint8_t>(index);
    }
    ControlFrame frame = {};
    TEST_ASSERT_EQUAL_UINT32(1 + 4 + 32 + 64, OTA_BEGIN_SIZE);  // v6: the signature too
    TEST_ASSERT_TRUE(decodeControlFrame(begin, sizeof(begin), frame));
    TEST_ASSERT_EQUAL_HEX8(FRAME_OTA_BEGIN, frame.type);
    TEST_ASSERT_EQUAL_UINT32(0x00091000U, frame.otaSize);
    TEST_ASSERT_EQUAL_UINT8_ARRAY(begin + 5, frame.otaSha256, SHA256_SIZE);
    TEST_ASSERT_EQUAL_UINT8_ARRAY(begin + 37, frame.otaSignature, OTA_SIGNATURE_SIZE);
    TEST_ASSERT_FALSE(decodeControlFrame(begin, sizeof(begin) - 1, frame));
    // The v4 frame, without a signature, is refused
    TEST_ASSERT_FALSE(decodeControlFrame(begin, 1 + 4 + SHA256_SIZE, frame));
    TEST_ASSERT_TRUE(MAX_CONTROL_FRAME_SIZE >= OTA_BEGIN_SIZE);

    const uint8_t abort[] = {FRAME_OTA_ABORT};
    const uint8_t abortTooLong[] = {FRAME_OTA_ABORT, 0};
    TEST_ASSERT_TRUE(decodeControlFrame(abort, sizeof(abort), frame));
    TEST_ASSERT_FALSE(decodeControlFrame(abortTooLong, sizeof(abortTooLong), frame));

    uint8_t status[OTA_STATUS_SIZE] = {};
    const uint8_t expected[] = {0x23, OTA_STATE_FAILED, OTA_ERROR_HASH_MISMATCH, 0x78, 0x56, 0x34, 0x12};
    TEST_ASSERT_EQUAL_UINT32(OTA_STATUS_SIZE, encodeOtaStatus(
        OTA_STATE_FAILED, OTA_ERROR_HASH_MISMATCH, 0x12345678U, status, sizeof(status)));
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, status, sizeof(expected));
    TEST_ASSERT_EQUAL_UINT32(0, encodeOtaStatus(0, 0, 0, status, sizeof(status)));
    TEST_ASSERT_EQUAL_UINT32(0, encodeOtaStatus(OTA_STATE_DONE, 0, 0, status, OTA_STATUS_SIZE - 1));

    const uint8_t chunk[] = {0x10, 0x00, 0x00, 0x00, 0xAA, 0xBB};
    uint32_t offset = 0;
    const uint8_t* data = nullptr;
    size_t length = 0;
    TEST_ASSERT_TRUE(decodeOtaData(chunk, sizeof(chunk), offset, data, length));
    TEST_ASSERT_EQUAL_UINT32(16, offset);
    TEST_ASSERT_EQUAL_UINT32(2, length);
    TEST_ASSERT_EQUAL_HEX8(0xAA, data[0]);
    TEST_ASSERT_FALSE(decodeOtaData(chunk, OTA_DATA_HEADER_SIZE, offset, data, length));
}

void test_the_wake_flag_is_not_the_photo_flag() {
    TEST_ASSERT_EQUAL_HEX32(0x40000000U, EchoBleProtocol::WAKE_SEGMENT_ID_FLAG);
    TEST_ASSERT_EQUAL_HEX32(0, EchoBleProtocol::WAKE_SEGMENT_ID_FLAG & EchoBleProtocol::PHOTO_SEGMENT_ID_FLAG);
}

void test_a_flagged_id_travels_whole_in_every_frame() {
    const uint32_t id = 7U | EchoBleProtocol::WAKE_SEGMENT_ID_FLAG;
    uint8_t frame[EchoBleProtocol::SEGMENT_START_SIZE];
    EchoBleProtocol::SegmentStart start = {id, EchoBleProtocol::PROTOCOL_VERSION, 10, 20, 1, 0};
    TEST_ASSERT_EQUAL(EchoBleProtocol::SEGMENT_START_SIZE,
                      EchoBleProtocol::encodeSegmentStart(start, frame, sizeof(frame)));
    EchoBleProtocol::SegmentStart back = {};
    TEST_ASSERT_TRUE(EchoBleProtocol::decodeSegmentStart(frame, sizeof(frame), back));
    TEST_ASSERT_EQUAL_HEX32(id, back.segmentId);

    const uint8_t uploadOk[] = {EchoBleProtocol::FRAME_UPLOAD_OK, 0x07, 0x00, 0x00, 0x40};
    EchoBleProtocol::ControlFrame control = {};
    TEST_ASSERT_TRUE(EchoBleProtocol::decodeControlFrame(uploadOk, sizeof(uploadOk), control));
    TEST_ASSERT_EQUAL_HEX32(id, control.segmentId);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_mic_gain_frame_takes_1_to_8);
    RUN_TEST(test_power_off_frame_turns_off_or_cancels);
    RUN_TEST(test_power_state_exact_bytes_and_protocol_unchanged);
    RUN_TEST(test_crc32_known_vector);
    RUN_TEST(test_incremental_crc32_matches_one_shot_crc32);
    RUN_TEST(test_buffered_segment_header_round_trips_stored_crc);
    RUN_TEST(test_buffered_segment_header_exact_bytes);
    RUN_TEST(test_buffered_segment_header_round_trips_the_unix_time_flag);
    RUN_TEST(test_a_legacy_header_decodes_as_boot_relative);
    RUN_TEST(test_recorded_at_of_a_boot_relative_segment_uses_the_anchor);
    RUN_TEST(test_recorded_at_of_a_unix_segment_is_its_own_time);
    RUN_TEST(test_recorded_at_of_an_unknown_time_segment_is_the_delivery_time);
    RUN_TEST(test_little_endian_round_trips);
    RUN_TEST(test_segment_start_exact_bytes);
    RUN_TEST(test_device_status_v2_exact_bytes_and_round_trips);
    RUN_TEST(test_device_status_says_whether_a_card_is_in_use_its_room_and_its_speech);
    RUN_TEST(test_device_info_exact_bytes_and_round_trips);
    RUN_TEST(test_status_and_info_reject_malformed_frames);
    RUN_TEST(test_status_and_info_encoders_reject_invalid_values_and_short_buffers);
    RUN_TEST(test_privacy_control_frames_decode_exact_lengths_and_values);
    RUN_TEST(test_set_time_exact_bytes);
    RUN_TEST(test_control_frames_reject_truncation_and_unknown_types);
    RUN_TEST(test_notification_payload_is_capped_by_att_and_characteristic_limits);
    RUN_TEST(test_protocol_encoders_accept_maximum_fields_and_reject_short_buffers);
    RUN_TEST(test_time_anchor_resolves_captures_before_and_after_set_time);
    RUN_TEST(test_time_anchor_uses_wrap_safe_millis_delta);
    RUN_TEST(test_status_frames_still_decode_with_the_valid_status);
    RUN_TEST(test_camera_flag_is_bit_two_of_the_status);
    RUN_TEST(test_photo_start_has_the_segment_start_layout_with_its_own_type);
    RUN_TEST(test_take_photo_and_photo_failed_frames);
    RUN_TEST(test_ota_frames);
    RUN_TEST(test_the_wake_flag_is_not_the_photo_flag);
    RUN_TEST(test_a_flagged_id_travels_whole_in_every_frame);
    return UNITY_END();
}