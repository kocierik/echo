#include <unity.h>

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

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_sequential_reservations_and_accounting);
    RUN_TEST(test_wrap_and_fifo_pop_jump_over_tail_gap);
    RUN_TEST(test_rejects_wrap_when_beginning_is_too_small);
    RUN_TEST(test_full_to_empty_resets_offsets);
    return UNITY_END();
}