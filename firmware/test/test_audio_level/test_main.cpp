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

#include <math.h>

static void fill(int16_t* frame, int count, int offset, double hz, double amplitude, int start) {
    for (int i = 0; i < count; i++) {
        frame[i] = (int16_t)(offset + amplitude * sin(2 * M_PI * hz * (start + i) / 16000.0));
    }
}

void test_the_offset_goes_from_the_first_sample() {
    HighPass filter;
    int16_t frame[512];
    for (int i = 0; i < 512; i++) frame[i] = 1400;
    filter.process(frame, 512, 3);
    TEST_ASSERT_EQUAL_INT16(0, frame[0]);
    TEST_ASSERT_EQUAL_UINT32(0, acRms(frame, 512));
}

void test_the_voice_passes_gain_times_louder() {
    HighPass filter;
    int16_t frame[512];
    for (int block = 0; block < 4; block++) {  // past the start
        fill(frame, 512, 1400, 1000, 300, block * 512);
        filter.process(frame, 512, 3);
    }
    TEST_ASSERT_UINT32_WITHIN(40, 900 / sqrt(2.0), acRms(frame, 512));
}

void test_rumble_is_cut() {
    HighPass filter;
    int16_t frame[512];
    for (int block = 0; block < 8; block++) {
        fill(frame, 512, 1400, 20, 1000, block * 512);
        filter.process(frame, 512, 1);
    }
    // 20 Hz, a fifth of the cutoff: about a fifth left
    TEST_ASSERT_LESS_THAN_UINT32(260, acRms(frame, 512));
}

void test_no_step_between_frames() {
    // The per-frame mean jumped at each boundary; the filter's state carries across
    HighPass filter;
    int16_t first[512], second[512];
    fill(first, 512, 1400, 20, 1000, 0);
    fill(second, 512, 1400, 20, 1000, 512);
    filter.process(first, 512, 1);
    filter.process(second, 512, 1);
    const int across = abs(second[0] - first[511]);
    const int within = abs(first[511] - first[510]);
    TEST_ASSERT_LESS_OR_EQUAL_INT(within + 2, across);
}

void test_loud_sound_clips_instead_of_wrapping() {
    HighPass filter;
    int16_t frame[2] = {0, 20000};
    filter.process(frame, 2, 3);
    TEST_ASSERT_EQUAL_INT16(32767, frame[1]);
}

void test_an_empty_frame_is_left_alone() {
    HighPass filter;
    filter.process(nullptr, 0, 3);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_constant_offset_is_silence);
    RUN_TEST(test_the_offset_goes_from_the_first_sample);
    RUN_TEST(test_the_voice_passes_gain_times_louder);
    RUN_TEST(test_rumble_is_cut);
    RUN_TEST(test_no_step_between_frames);
    RUN_TEST(test_loud_sound_clips_instead_of_wrapping);
    RUN_TEST(test_an_empty_frame_is_left_alone);
    RUN_TEST(test_sound_on_top_of_the_offset_is_measured_alone);
    RUN_TEST(test_a_negative_offset_too);
    RUN_TEST(test_an_empty_frame_is_silence);
    RUN_TEST(test_full_scale_does_not_overflow);
    return UNITY_END();
}
