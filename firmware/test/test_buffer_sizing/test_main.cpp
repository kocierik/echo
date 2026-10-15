#include <unity.h>

#include "buffer_sizing.h"

constexpr size_t MB = 1024 * 1024;
constexpr size_t KB = 1024;

void test_takes_what_it_wants_when_there_is_room() {
    TEST_ASSERT_EQUAL_UINT32(6 * MB, chooseBufferCapacity(6 * MB, 7 * MB, 768 * KB, 240 * KB));
}

void test_leaves_the_reserve_free_when_short() {
    TEST_ASSERT_EQUAL_UINT32(
        4 * MB - 768 * KB, chooseBufferCapacity(6 * MB, 4 * MB, 768 * KB, 240 * KB));
}

void test_gives_up_below_the_minimum() {
    TEST_ASSERT_EQUAL_UINT32(0, chooseBufferCapacity(6 * MB, 900 * KB, 768 * KB, 240 * KB));
    TEST_ASSERT_EQUAL_UINT32(0, chooseBufferCapacity(6 * MB, 500 * KB, 768 * KB, 240 * KB));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_takes_what_it_wants_when_there_is_room);
    RUN_TEST(test_leaves_the_reserve_free_when_short);
    RUN_TEST(test_gives_up_below_the_minimum);
    return UNITY_END();
}
