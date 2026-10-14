#include <unity.h>

#include <cstdint>
#include <cstring>

#include "photo_slot.h"

using namespace EchoBleProtocol;

static uint8_t storage[64];

static void fill(PhotoSlot& slot, const char* jpeg, uint32_t capturedAtMs) {
    TEST_ASSERT_TRUE(slot.beginCapture());
    const size_t length = std::strlen(jpeg);
    std::memcpy(slot.buffer(), jpeg, length);
    slot.captureDone(length, capturedAtMs);
}

void test_a_photo_goes_from_request_to_ready_to_released() {
    PhotoSlot slot;
    slot.attach(storage, sizeof(storage));

    TEST_ASSERT_TRUE(slot.request());
    TEST_ASSERT_FALSE(slot.request());  // busy until released
    TEST_ASSERT_FALSE(slot.isReady());
    fill(slot, "JPEGDATA", 4242U);

    TEST_ASSERT_TRUE(slot.isReady());
    const BufferedSegment segment = slot.segment();
    TEST_ASSERT_TRUE((segment.segmentId & PHOTO_SEGMENT_ID_FLAG) != 0);
    TEST_ASSERT_EQUAL_UINT32(8, segment.dataLength);
    TEST_ASSERT_EQUAL_UINT32(0, segment.durationMs);
    TEST_ASSERT_EQUAL_UINT32(4242U, segment.capturedAtMs);
    TEST_ASSERT_EQUAL_HEX32(crc32(reinterpret_cast<const uint8_t*>("JPEGDATA"), 8), segment.crc);
    TEST_ASSERT_EQUAL_MEMORY("JPEGDATA", slot.data(), 8);

    TEST_ASSERT_FALSE(slot.release(segment.segmentId + 1));  // another transfer's UPLOAD_OK
    TEST_ASSERT_TRUE(slot.release(segment.segmentId));
    TEST_ASSERT_EQUAL(PhotoSlot::EMPTY, slot.state());
    TEST_ASSERT_TRUE(slot.request());
}

void test_each_photo_gets_a_new_id() {
    PhotoSlot slot;
    slot.attach(storage, sizeof(storage));
    slot.request();
    fill(slot, "A", 1);
    const uint32_t first = slot.segment().segmentId;
    slot.release(first);
    slot.request();
    fill(slot, "B", 2);
    TEST_ASSERT_NOT_EQUAL(first, slot.segment().segmentId);
}

void test_a_failure_is_reported_once_and_frees_the_slot() {
    PhotoSlot slot;
    slot.attach(storage, sizeof(storage));
    uint8_t reason = 0;
    TEST_ASSERT_FALSE(slot.takeFailure(reason));

    slot.request();
    TEST_ASSERT_TRUE(slot.beginCapture());
    slot.captureFailed(PHOTO_FAILED_CAPTURE);

    TEST_ASSERT_TRUE(slot.takeFailure(reason));
    TEST_ASSERT_EQUAL_UINT8(PHOTO_FAILED_CAPTURE, reason);
    TEST_ASSERT_FALSE(slot.takeFailure(reason));
    TEST_ASSERT_TRUE(slot.request());
}

void test_muting_withdraws_a_request_and_drops_a_ready_photo() {
    PhotoSlot slot;
    slot.attach(storage, sizeof(storage));

    slot.request();
    TEST_ASSERT_TRUE(slot.discard());
    TEST_ASSERT_FALSE(slot.beginCapture());  // the camera task skips it

    slot.request();
    TEST_ASSERT_TRUE(slot.beginCapture());
    TEST_ASSERT_FALSE(slot.discard());  // a capture under way finishes first
    slot.captureDone(1, 1);
    TEST_ASSERT_TRUE(slot.discard());
    TEST_ASSERT_EQUAL(PhotoSlot::EMPTY, slot.state());
}

void test_without_a_buffer_nothing_can_be_requested() {
    PhotoSlot slot;
    TEST_ASSERT_FALSE(slot.hasBuffer());
    TEST_ASSERT_FALSE(slot.request());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_a_photo_goes_from_request_to_ready_to_released);
    RUN_TEST(test_each_photo_gets_a_new_id);
    RUN_TEST(test_a_failure_is_reported_once_and_frees_the_slot);
    RUN_TEST(test_muting_withdraws_a_request_and_drops_a_ready_photo);
    RUN_TEST(test_without_a_buffer_nothing_can_be_requested);
    return UNITY_END();
}
