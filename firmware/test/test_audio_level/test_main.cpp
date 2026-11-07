#include <unity.h>

#include <stdint.h>

#include "audio_level.h"

// The XIAO Sense PDM microphone reads with an offset of ~1400: measured raw, silence
// looked like speech to a threshold of 500 (every segment 6 s, transcribed empty)

void test_a_constant_offset_is_silence() {
    int16_t frame[512];
    for (int i = 0; i < 512; i++) frame[i] = 1400;
    TEST_ASSERT_EQUAL_UINT32(0, acRms(frame, 512));
}

void test_sound_on_top_of_the_offset_is_measured_alone() {
    int16_t frame[512];
    for (int i = 0; i < 512; i++) frame[i] = 1400 + ((i % 2 == 0) ? 1000 : -1000);
    TEST_ASSERT_UINT32_WITHIN(2, 1000, acRms(frame, 512));
}

void test_a_negative_offset_too() {
    int16_t frame[256];
    for (int i = 0; i < 256; i++) frame[i] = -3000 + ((i % 2 == 0) ? 300 : -300);
    TEST_ASSERT_UINT32_WITHIN(2, 300, acRms(frame, 256));
}

void test_an_empty_frame_is_silence() {
    TEST_ASSERT_EQUAL_UINT32(0, acRms(nullptr, 0));
}

void test_full_scale_does_not_overflow() {
    int16_t frame[512];
    for (int i = 0; i < 512; i++) frame[i] = (i % 2 == 0) ? 32767 : -32768;
    TEST_ASSERT_UINT32_WITHIN(2, 32767, acRms(frame, 512));
}

void test_amplify_takes_the_offset_away_then_multiplies() {
    int16_t frame[4] = {1400 + 100, 1400 - 100, 1400 + 100, 1400 - 100};
    amplify(frame, 4, 3);
    TEST_ASSERT_EQUAL_INT16(300, frame[0]);
    TEST_ASSERT_EQUAL_INT16(-300, frame[1]);
}

void test_amplify_clips_instead_of_wrapping() {
    int16_t frame[2] = {20000, -20000};
    amplify(frame, 2, 3);
    TEST_ASSERT_EQUAL_INT16(32767, frame[0]);
    TEST_ASSERT_EQUAL_INT16(-32768, frame[1]);
}

void test_amplify_leaves_an_empty_frame() {
    amplify(nullptr, 0, 3);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_constant_offset_is_silence);
    RUN_TEST(test_amplify_takes_the_offset_away_then_multiplies);
    RUN_TEST(test_amplify_clips_instead_of_wrapping);
    RUN_TEST(test_amplify_leaves_an_empty_frame);
    RUN_TEST(test_sound_on_top_of_the_offset_is_measured_alone);
    RUN_TEST(test_a_negative_offset_too);
    RUN_TEST(test_an_empty_frame_is_silence);
    RUN_TEST(test_full_scale_does_not_overflow);
    return UNITY_END();
}
