#include <unity.h>

#include "power_off_policy.h"

using State = PowerOffPolicy::State;
using Request = PowerOffPolicy::Request;

void test_a_request_starts_turning_off_once() {
    PowerOffPolicy policy;
    TEST_ASSERT_TRUE(policy.state() == State::ON);
    TEST_ASSERT_TRUE(policy.request(false) == Request::ACCEPTED);
    TEST_ASSERT_TRUE(policy.state() == State::TURNING_OFF);
    TEST_ASSERT_TRUE(policy.request(false) == Request::ALREADY_TURNING_OFF);
}

void test_refused_while_updating() {
    PowerOffPolicy policy;
    TEST_ASSERT_TRUE(policy.request(true) == Request::REFUSED_UPDATING);
    TEST_ASSERT_TRUE(policy.state() == State::ON);
}

void test_it_spills_to_the_card_then_sleeps_once_psram_is_empty() {
    PowerOffPolicy policy;
    policy.request(false);
    TEST_ASSERT_TRUE(policy.shouldSpill(true));
    TEST_ASSERT_TRUE(policy.update(2) == State::TURNING_OFF);
    TEST_ASSERT_TRUE(policy.update(0) == State::OFF_NOW);
}

void test_a_refusing_card_waits_for_the_phone() {
    PowerOffPolicy policy;
    policy.request(false);
    policy.onCardRefused();
    TEST_ASSERT_FALSE(policy.shouldSpill(true));
    for (int i = 0; i < 1000; ++i) TEST_ASSERT_TRUE(policy.update(3) == State::TURNING_OFF);
    TEST_ASSERT_TRUE(policy.update(0) == State::OFF_NOW);
}

void test_without_a_card_it_never_spills() {
    PowerOffPolicy policy;
    policy.request(false);
    TEST_ASSERT_FALSE(policy.shouldSpill(false));
}

void test_cancel_turns_it_back_on_and_a_new_request_tries_the_card_again() {
    PowerOffPolicy policy;
    TEST_ASSERT_FALSE(policy.cancel());
    policy.request(false);
    policy.onCardRefused();
    TEST_ASSERT_TRUE(policy.cancel());
    TEST_ASSERT_TRUE(policy.state() == State::ON);
    TEST_ASSERT_TRUE(policy.request(false) == Request::ACCEPTED);
    TEST_ASSERT_TRUE(policy.shouldSpill(true));
}

void test_while_on_an_empty_psram_does_not_turn_it_off() {
    PowerOffPolicy policy;
    TEST_ASSERT_TRUE(policy.update(0) == State::ON);
    TEST_ASSERT_FALSE(policy.shouldSpill(true));
}

void test_once_off_now_it_cannot_be_cancelled() {
    PowerOffPolicy policy;
    policy.request(false);
    policy.update(0);
    TEST_ASSERT_FALSE(policy.cancel());
    TEST_ASSERT_TRUE(policy.state() == State::OFF_NOW);
    TEST_ASSERT_TRUE(policy.request(false) == Request::ALREADY_TURNING_OFF);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_a_request_starts_turning_off_once);
    RUN_TEST(test_refused_while_updating);
    RUN_TEST(test_it_spills_to_the_card_then_sleeps_once_psram_is_empty);
    RUN_TEST(test_a_refusing_card_waits_for_the_phone);
    RUN_TEST(test_without_a_card_it_never_spills);
    RUN_TEST(test_cancel_turns_it_back_on_and_a_new_request_tries_the_card_again);
    RUN_TEST(test_while_on_an_empty_psram_does_not_turn_it_off);
    RUN_TEST(test_once_off_now_it_cannot_be_cancelled);
    return UNITY_END();
}
