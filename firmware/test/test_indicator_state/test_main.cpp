#include <unity.h>

#include "indicator_state.h"

void test_stable_press_toggles_once() {
    ButtonDebouncer button(true, 50);

    TEST_ASSERT_FALSE(button.update(false, 10));
    TEST_ASSERT_FALSE(button.update(false, 59));
    TEST_ASSERT_TRUE(button.update(false, 60));
    TEST_ASSERT_FALSE(button.update(false, 100));
}

void test_bounce_is_rejected() {
    ButtonDebouncer button(true, 50);

    TEST_ASSERT_FALSE(button.update(false, 10));
    TEST_ASSERT_FALSE(button.update(true, 20));
    TEST_ASSERT_FALSE(button.update(false, 30));
    TEST_ASSERT_FALSE(button.update(false, 79));
    TEST_ASSERT_TRUE(button.update(false, 80));
}

void test_release_then_repress_toggles_again() {
    ButtonDebouncer button(true, 50);

    TEST_ASSERT_FALSE(button.update(false, 10));
    TEST_ASSERT_TRUE(button.update(false, 60));
    TEST_ASSERT_FALSE(button.update(true, 70));
    TEST_ASSERT_FALSE(button.update(true, 120));
    TEST_ASSERT_FALSE(button.update(false, 130));
    TEST_ASSERT_TRUE(button.update(false, 180));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_stable_press_toggles_once);
    RUN_TEST(test_bounce_is_rejected);
    RUN_TEST(test_release_then_repress_toggles_again);
    return UNITY_END();
}