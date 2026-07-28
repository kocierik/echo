#include <unity.h>

#include <cstdint>
#include <cstring>

#include "ble_protocol.h"

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
        0x78563412U, 1U, 0x44332211U, 0x88776655U, 0xAA99U, 0xDDCCBBAAU};
    const uint8_t expected[] = {
        0x01, 0x12, 0x34, 0x56, 0x78, 0x01, 0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xAA, 0xBB, 0xCC, 0xDD};
    uint8_t encoded[SEGMENT_START_SIZE] = {};

    TEST_ASSERT_EQUAL_UINT32(SEGMENT_START_SIZE, encodeSegmentStart(frame, encoded, sizeof(encoded)));
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, encoded, sizeof(expected));

    SegmentStart decoded = {};
    TEST_ASSERT_TRUE(decodeSegmentStart(encoded, sizeof(encoded), decoded));
    TEST_ASSERT_EQUAL_HEX32(frame.segmentId, decoded.segmentId);
    TEST_ASSERT_EQUAL_HEX32(frame.crc, decoded.crc);
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

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_crc32_known_vector);
    RUN_TEST(test_incremental_crc32_matches_one_shot_crc32);
    RUN_TEST(test_little_endian_round_trips);
    RUN_TEST(test_segment_start_exact_bytes);
    RUN_TEST(test_set_time_exact_bytes);
    RUN_TEST(test_control_frames_reject_truncation_and_unknown_types);
    RUN_TEST(test_notification_payload_is_capped_by_att_and_characteristic_limits);
    RUN_TEST(test_protocol_encoders_accept_maximum_fields_and_reject_short_buffers);
    RUN_TEST(test_time_anchor_resolves_captures_before_and_after_set_time);
    RUN_TEST(test_time_anchor_uses_wrap_safe_millis_delta);
    return UNITY_END();
}