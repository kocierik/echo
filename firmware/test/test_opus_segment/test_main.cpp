#include <unity.h>

#include <stdint.h>
#include <string.h>

#include "opus_segment.h"

// A codec that packs each frame into `size` bytes holding its first sample's low byte
struct FakeCodec {
    int size = 40;
    int resets = 0;
    int frames = 0;
    void reset() { resets++; }
    int encode(const int16_t* pcm, size_t samples, uint8_t* out, size_t capacity) {
        TEST_ASSERT_EQUAL(OpusSegment::FRAME_SAMPLES, samples);
        frames++;
        if ((size_t)size > capacity) return -2;  // OPUS_BUFFER_TOO_SMALL
        memset(out, pcm[0] & 0xFF, size);
        return size;
    }
};

static int16_t samples[1024];
static uint8_t out[4096];

void setUp() {
    for (int i = 0; i < 1024; i++) samples[i] = (int16_t)i;
}
void tearDown() {}

void test_a_segment_starts_with_the_magic_and_a_fresh_codec() {
    FakeCodec codec;
    OpusSegmentWriter<FakeCodec> writer(codec);

    TEST_ASSERT_EQUAL(4, writer.begin(out));
    TEST_ASSERT_EQUAL_MEMORY("EOP1", out, 4);
    TEST_ASSERT_EQUAL(1, codec.resets);
}

void test_frames_of_twenty_milliseconds_each_with_its_length() {
    FakeCodec codec;
    OpusSegmentWriter<FakeCodec> writer(codec);
    writer.begin(out);

    // 512 samples (a VAD frame): one whole frame of 320, 192 waiting
    size_t written = writer.write(samples, 512, out, sizeof(out));
    TEST_ASSERT_EQUAL(1 + 40, written);
    TEST_ASSERT_EQUAL(40, out[0]);
    // Another 512: completes the second (320 at 320) and a third at 960
    written = writer.write(samples + 512, 512, out, sizeof(out));
    TEST_ASSERT_EQUAL(2 * (1 + 40), written);
    TEST_ASSERT_EQUAL(3, codec.frames);
}

void test_the_last_part_of_a_frame_is_filled_with_silence() {
    FakeCodec codec;
    OpusSegmentWriter<FakeCodec> writer(codec);
    writer.begin(out);
    writer.write(samples, 400, out, sizeof(out));  // one frame, 80 waiting

    TEST_ASSERT_EQUAL(1 + 40, writer.finish(out, sizeof(out)));
    TEST_ASSERT_EQUAL(0, writer.finish(out, sizeof(out)));  // nothing waiting
    TEST_ASSERT_EQUAL(2, codec.frames);
}

void test_a_packet_never_needs_more_than_one_length_byte() {
    FakeCodec codec;
    codec.size = 300;  // more than fits: the codec is given at most 255
    OpusSegmentWriter<FakeCodec> writer(codec);
    writer.begin(out);

    // Refused: the frame is dropped, nothing written
    TEST_ASSERT_EQUAL(0, writer.write(samples, 320, out, sizeof(out)));
    codec.size = 255;
    TEST_ASSERT_EQUAL(256, writer.write(samples, 320, out, sizeof(out)));
    TEST_ASSERT_EQUAL(255, out[0]);
}

void test_no_room_writes_nothing() {
    FakeCodec codec;
    OpusSegmentWriter<FakeCodec> writer(codec);
    writer.begin(out);

    TEST_ASSERT_EQUAL(0, writer.write(samples, 320, out, 1));
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_segment_starts_with_the_magic_and_a_fresh_codec);
    RUN_TEST(test_frames_of_twenty_milliseconds_each_with_its_length);
    RUN_TEST(test_the_last_part_of_a_frame_is_filled_with_silence);
    RUN_TEST(test_a_packet_never_needs_more_than_one_length_byte);
    RUN_TEST(test_no_room_writes_nothing);
    return UNITY_END();
}
