#include <unity.h>

#include "buffered_segment.h"
#include "ring_buffer_layout.h"

void test_sequential_reservations_and_accounting() {
    RingBufferLayout layout(100);
    size_t offset = 0;
    TEST_ASSERT_TRUE(layout.reserve(30, offset));
    TEST_ASSERT_EQUAL_UINT32(0, offset);
    TEST_ASSERT_TRUE(layout.reserve(20, offset));
    TEST_ASSERT_EQUAL_UINT32(30, offset);
    TEST_ASSERT_EQUAL_UINT16(2, layout.count());
    TEST_ASSERT_EQUAL_UINT32(50, layout.bytesUsed());
}

void test_wrap_and_fifo_pop_jump_over_tail_gap() {
    RingBufferLayout layout(100);
    size_t offset = 0;
    TEST_ASSERT_TRUE(layout.reserve(60, offset));
    TEST_ASSERT_TRUE(layout.reserve(30, offset));
    layout.pop(60);
    TEST_ASSERT_TRUE(layout.reserve(40, offset));
    TEST_ASSERT_EQUAL_UINT32(0, offset);
    TEST_ASSERT_EQUAL_UINT32(60, layout.frontOffset());
    layout.pop(30);
    TEST_ASSERT_EQUAL_UINT32(0, layout.frontOffset());
    TEST_ASSERT_EQUAL_UINT16(1, layout.count());
}

void test_rejects_wrap_when_beginning_is_too_small() {
    RingBufferLayout layout(100);
    size_t offset = 0;
    TEST_ASSERT_TRUE(layout.reserve(20, offset));
    TEST_ASSERT_TRUE(layout.reserve(50, offset));
    layout.pop(20);
    TEST_ASSERT_FALSE(layout.reserve(40, offset));
    TEST_ASSERT_EQUAL_UINT16(1, layout.count());
    TEST_ASSERT_EQUAL_UINT32(50, layout.bytesUsed());
}

void test_full_to_empty_resets_offsets() {
    RingBufferLayout layout(64);
    size_t offset = 99;
    TEST_ASSERT_TRUE(layout.reserve(64, offset));
    TEST_ASSERT_EQUAL_UINT32(0, offset);
    TEST_ASSERT_FALSE(layout.reserve(1, offset));
    layout.pop(64);
    TEST_ASSERT_EQUAL_UINT16(0, layout.count());
    TEST_ASSERT_EQUAL_UINT32(0, layout.bytesUsed());
    TEST_ASSERT_TRUE(layout.reserve(16, offset));
    TEST_ASSERT_EQUAL_UINT32(0, offset);
}

void test_enlarged_segment_headers_wrap_without_losing_fifo_order() {
    constexpr size_t entrySize = BufferedSegmentCodec::HEADER_SIZE + 10;
    RingBufferLayout layout(80);
    size_t offset = 0;

    TEST_ASSERT_TRUE(layout.reserve(entrySize, offset));
    TEST_ASSERT_EQUAL_UINT32(0, offset);
    TEST_ASSERT_TRUE(layout.reserve(entrySize, offset));
    TEST_ASSERT_EQUAL_UINT32(entrySize, offset);
    layout.pop(entrySize);
    TEST_ASSERT_TRUE(layout.reserve(entrySize, offset));
    TEST_ASSERT_EQUAL_UINT32(0, offset);
    TEST_ASSERT_EQUAL_UINT32(entrySize, layout.frontOffset());
    layout.pop(entrySize);
    TEST_ASSERT_EQUAL_UINT32(0, layout.frontOffset());
    TEST_ASSERT_EQUAL_UINT16(1, layout.count());
}

void test_drop_oldest_allows_fragmented_reservation_to_retry_and_wrap() {
    RingBufferLayout layout(100);
    size_t offset = 0;

    TEST_ASSERT_TRUE(layout.reserve(30, offset));
    TEST_ASSERT_EQUAL_UINT32(0, offset);
    TEST_ASSERT_TRUE(layout.reserve(30, offset));
    TEST_ASSERT_EQUAL_UINT32(30, offset);
    TEST_ASSERT_TRUE(layout.reserve(30, offset));
    TEST_ASSERT_EQUAL_UINT32(60, offset);

    layout.pop(30);
    TEST_ASSERT_FALSE(layout.reserve(35, offset));
    TEST_ASSERT_EQUAL_UINT32(30, layout.frontOffset());

    layout.pop(30);
    TEST_ASSERT_TRUE(layout.reserve(35, offset));
    TEST_ASSERT_EQUAL_UINT32(0, offset);
    TEST_ASSERT_EQUAL_UINT32(60, layout.frontOffset());

    layout.pop(30);
    TEST_ASSERT_EQUAL_UINT32(0, layout.frontOffset());
    TEST_ASSERT_EQUAL_UINT16(1, layout.count());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_sequential_reservations_and_accounting);
    RUN_TEST(test_wrap_and_fifo_pop_jump_over_tail_gap);
    RUN_TEST(test_rejects_wrap_when_beginning_is_too_small);
    RUN_TEST(test_full_to_empty_resets_offsets);
    RUN_TEST(test_enlarged_segment_headers_wrap_without_losing_fifo_order);
    RUN_TEST(test_drop_oldest_allows_fragmented_reservation_to_retry_and_wrap);
    return UNITY_END();
}