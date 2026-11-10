#include <unity.h>

#include "wake_gate.h"

using Decision = WakeGate::Decision;

void test_a_hold_long_enough_boots() {
    WakeGate gate(1500, 50);
    TEST_ASSERT_TRUE(gate.update(true, 0) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(true, 1499) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(true, 1500) == Decision::BOOT);
}

void test_released_early_it_sleeps_again_after_the_debounce() {
    WakeGate gate(1500, 50);
    gate.update(true, 0);
    TEST_ASSERT_TRUE(gate.update(false, 400) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(false, 449) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(false, 450) == Decision::SLEEP);
}

void test_a_bounce_does_not_send_it_back_to_sleep() {
    WakeGate gate(1500, 50);
    gate.update(true, 0);
    gate.update(false, 100);
    TEST_ASSERT_TRUE(gate.update(true, 120) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(false, 130) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(true, 140) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(true, 1500) == Decision::BOOT);
}

void test_a_glitch_with_the_button_up_sleeps_again() {
    WakeGate gate(1500, 50);
    TEST_ASSERT_TRUE(gate.update(false, 0) == Decision::WAIT);
    TEST_ASSERT_TRUE(gate.update(false, 50) == Decision::SLEEP);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_a_hold_long_enough_boots);
    RUN_TEST(test_released_early_it_sleeps_again_after_the_debounce);
    RUN_TEST(test_a_bounce_does_not_send_it_back_to_sleep);
    RUN_TEST(test_a_glitch_with_the_button_up_sleeps_again);
    return UNITY_END();
}
