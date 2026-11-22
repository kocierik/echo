#include <unity.h>

#include "link_watch.h"

static constexpr uint32_t QUIET = LinkWatch::QUIET_MS;
static constexpr uint32_t STUCK = 60000;

void test_advertising_with_no_phone_needs_nothing() {
    LinkWatch watch(STUCK);
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(0, false, false, true));
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(600000, false, false, true));
}

void test_silent_with_no_phone_advertises_again_after_a_grace() {
    LinkWatch watch(STUCK);
    // Right after a disconnect NimBLE restarts advertising itself: no race with it
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(1000, false, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(1000 + QUIET - 1, false, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::ADVERTISE, watch.update(1000 + QUIET, false, false, false));
    // Still silent: tried again after another grace, not on every loop
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(1000 + QUIET + 1, false, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::ADVERTISE, watch.update(1000 + 2 * QUIET, false, false, false));
}

void test_a_ready_link_is_left_alone() {
    LinkWatch watch(STUCK);
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(0, true, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(5000, true, true, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(3600000, true, true, false));
}

void test_a_link_never_ready_is_dropped() {
    LinkWatch watch(STUCK);
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(1000, true, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(1000 + STUCK - 1, true, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::DROP_LINK, watch.update(1000 + STUCK, true, false, false));
    // The drop takes a moment: not asked again on the next loop
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(1000 + STUCK + 1, true, false, false));
}

void test_a_link_that_was_ready_gets_the_full_wait_again() {
    LinkWatch watch(STUCK);
    watch.update(0, true, true, false);
    // The app went quiet (reconnecting its side): counted from when it stopped being ready
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(100000, true, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(100000 + STUCK - 1, true, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::DROP_LINK, watch.update(100000 + STUCK, true, false, false));
}

void test_millis_wrapping_does_not_fire_early() {
    LinkWatch watch(STUCK);
    const uint32_t start = UINT32_MAX - 1000;
    watch.update(start, true, false, false);
    TEST_ASSERT_EQUAL(LinkWatch::Action::NONE, watch.update(start + 2000, true, false, false));
    TEST_ASSERT_EQUAL(LinkWatch::Action::DROP_LINK, watch.update(start + STUCK, true, false, false));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_advertising_with_no_phone_needs_nothing);
    RUN_TEST(test_silent_with_no_phone_advertises_again_after_a_grace);
    RUN_TEST(test_a_ready_link_is_left_alone);
    RUN_TEST(test_a_link_never_ready_is_dropped);
    RUN_TEST(test_a_link_that_was_ready_gets_the_full_wait_again);
    RUN_TEST(test_millis_wrapping_does_not_fire_early);
    return UNITY_END();
}
