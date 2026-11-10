#include <unity.h>

#include "button_gesture.h"

using Event = ButtonGesture::Event;

void test_a_short_press_fires_on_release() {
    ButtonGesture button(50, 1500, 5000);
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 0));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 60));   // debounced: pressed
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 400));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 420));
    TEST_ASSERT_EQUAL(Event::SHORT_PRESS, button.update(false, 480));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 600));
}

void test_a_long_press_fires_on_release_not_while_held() {
    ButtonGesture button(50, 1500, 5000);
    button.update(true, 0);
    button.update(true, 60);
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 1500));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 3000));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 3010));  // still debouncing
    TEST_ASSERT_EQUAL(Event::LONG_PRESS, button.update(false, 3060));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 3200));
}

void test_a_very_long_press_fires_while_held_and_nothing_on_release() {
    ButtonGesture button(50, 1500, 5000);
    button.update(true, 0);
    button.update(true, 60);
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 4999));
    TEST_ASSERT_EQUAL(Event::VERY_LONG_PRESS, button.update(true, 5000));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(true, 7000));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 7010));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 7100));  // no long press too
}

void test_bounces_are_ignored() {
    ButtonGesture button(50, 1500, 5000);
    button.update(true, 0);
    button.update(false, 10);
    button.update(true, 20);
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 30));
    TEST_ASSERT_EQUAL(Event::NONE, button.update(false, 200));  // never stably pressed
}

void test_presses_follow_one_another() {
    ButtonGesture button(50, 1500, 5000);
    button.update(true, 0);
    button.update(true, 60);
    button.update(false, 100);
    TEST_ASSERT_EQUAL(Event::SHORT_PRESS, button.update(false, 160));
    button.update(true, 300);
    button.update(true, 360);
    button.update(false, 2000);
    TEST_ASSERT_EQUAL(Event::LONG_PRESS, button.update(false, 2050));
    button.update(true, 2200);
    button.update(true, 2260);
    TEST_ASSERT_EQUAL(Event::VERY_LONG_PRESS, button.update(true, 7200));
}

void test_millis_wraparound() {
    const uint32_t start = 0xFFFFFF00U;
    ButtonGesture longPress(50, 1500, 5000);
    longPress.update(true, start);
    longPress.update(true, start + 60);
    longPress.update(false, start + 1600);
    TEST_ASSERT_EQUAL(Event::LONG_PRESS, longPress.update(false, start + 1660));

    ButtonGesture veryLong(50, 1500, 5000);
    veryLong.update(true, start);
    veryLong.update(true, start + 60);
    TEST_ASSERT_EQUAL(Event::VERY_LONG_PRESS, veryLong.update(true, start + 5000));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_a_short_press_fires_on_release);
    RUN_TEST(test_a_long_press_fires_on_release_not_while_held);
    RUN_TEST(test_a_very_long_press_fires_while_held_and_nothing_on_release);
    RUN_TEST(test_bounces_are_ignored);
    RUN_TEST(test_presses_follow_one_another);
    RUN_TEST(test_millis_wraparound);
    return UNITY_END();
}