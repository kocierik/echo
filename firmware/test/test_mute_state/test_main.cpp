#include <unity.h>

#include "mute_state.h"

void test_persisted_true_boots_muted() {
    MuteState muteState(
        [](bool& muted) {
            muted = true;
            return true;
        },
        [](bool) { return true; });

    TEST_ASSERT_TRUE(muteState.begin());
    TEST_ASSERT_TRUE(muteState.isMuted());
}

void test_default_boots_listening() {
    MuteState muteState(
        [](bool& muted) {
            muted = false;
            return true;
        },
        [](bool) { return true; });

    TEST_ASSERT_TRUE(muteState.begin());
    TEST_ASSERT_FALSE(muteState.isMuted());
}

void test_listening_to_muted_persists_true() {
    bool savedValue = false;
    MuteState muteState(
        [](bool& muted) {
            muted = false;
            return true;
        },
        [&savedValue](bool muted) {
            savedValue = muted;
            return true;
        });
    TEST_ASSERT_TRUE(muteState.begin());

    TEST_ASSERT_TRUE(muteState.setMuted(true));
    TEST_ASSERT_TRUE(muteState.isMuted());
    TEST_ASSERT_TRUE(savedValue);
}

void test_muted_to_listening_persists_false() {
    bool savedValue = true;
    MuteState muteState(
        [](bool& muted) {
            muted = true;
            return true;
        },
        [&savedValue](bool muted) {
            savedValue = muted;
            return true;
        });
    TEST_ASSERT_TRUE(muteState.begin());

    TEST_ASSERT_TRUE(muteState.setMuted(false));
    TEST_ASSERT_FALSE(muteState.isMuted());
    TEST_ASSERT_FALSE(savedValue);
}

void test_duplicate_command_does_not_save_again() {
    unsigned int saveCount = 0;
    MuteState muteState(
        [](bool& muted) {
            muted = false;
            return true;
        },
        [&saveCount](bool) {
            ++saveCount;
            return true;
        });
    TEST_ASSERT_TRUE(muteState.begin());

    TEST_ASSERT_TRUE(muteState.setMuted(true));
    TEST_ASSERT_TRUE(muteState.setMuted(true));
    TEST_ASSERT_EQUAL_UINT32(1, saveCount);
}

void test_save_failure_keeps_requested_in_memory_state() {
    MuteState muteState(
        [](bool& muted) {
            muted = false;
            return true;
        },
        [](bool) { return false; });
    TEST_ASSERT_TRUE(muteState.begin());

    TEST_ASSERT_FALSE(muteState.setMuted(true));
    TEST_ASSERT_TRUE(muteState.isMuted());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_persisted_true_boots_muted);
    RUN_TEST(test_default_boots_listening);
    RUN_TEST(test_listening_to_muted_persists_true);
    RUN_TEST(test_muted_to_listening_persists_false);
    RUN_TEST(test_duplicate_command_does_not_save_again);
    RUN_TEST(test_save_failure_keeps_requested_in_memory_state);
    return UNITY_END();
}