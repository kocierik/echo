#include <unity.h>

#include "wake_window.h"

void test_the_name_in_the_opening_counts_once() {
    WakeWindow w(4000);
    w.segmentStarted(10000);
    TEST_ASSERT_FALSE(w.heard(false, 10500));
    TEST_ASSERT_TRUE(w.heard(true, 10800));
    TEST_ASSERT_FALSE(w.heard(true, 10900));
    TEST_ASSERT_TRUE(w.segmentHeard());
}

void test_the_name_late_in_a_sentence_does_not_count() {
    WakeWindow w(4000);
    w.segmentStarted(10000);
    TEST_ASSERT_FALSE(w.heard(true, 14001));
    TEST_ASSERT_FALSE(w.segmentHeard());
}

void test_the_name_outside_a_segment_does_not_count() {
    WakeWindow w(4000);
    TEST_ASSERT_FALSE(w.heard(true, 500));
    w.segmentStarted(1000);
    TEST_ASSERT_FALSE(w.segmentHeard());
}

void test_a_discarded_segment_leaves_nothing_behind() {
    WakeWindow w(4000);
    w.segmentStarted(0);
    w.heard(true, 300);
    w.segmentEnded();
    TEST_ASSERT_FALSE(w.segmentHeard());
    w.segmentStarted(9000);
    TEST_ASSERT_TRUE(w.heard(true, 9400));
}

void test_the_window_survives_the_millis_wrap() {
    WakeWindow w(4000);
    w.segmentStarted(0xFFFFFF00U);
    TEST_ASSERT_TRUE(w.heard(true, 0x00000200U));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_the_name_in_the_opening_counts_once);
    RUN_TEST(test_the_name_late_in_a_sentence_does_not_count);
    RUN_TEST(test_the_name_outside_a_segment_does_not_count);
    RUN_TEST(test_a_discarded_segment_leaves_nothing_behind);
    RUN_TEST(test_the_window_survives_the_millis_wrap);
    return UNITY_END();
}
