#include <unity.h>

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "buffered_segment.h"
#include "ring_buffer_layout.h"

class OverflowBufferFixture {
public:
    static constexpr size_t CAPACITY = 100;
    static constexpr size_t PAYLOAD_SIZE = 4;

    bool store(uint32_t segmentId, const uint8_t* payload) {
        const size_t entrySize = BufferedSegmentCodec::HEADER_SIZE + PAYLOAD_SIZE;
        size_t offset = 0;
        if (!_layout.reserve(entrySize, offset)) return false;

        const BufferedSegment header = {
            segmentId,
            PAYLOAD_SIZE,
            1000,
            0,
            segmentId * 1000,
            100,
            segmentId,
        };
        BufferedSegmentCodec::encode(header, _storage + offset);
        memcpy(_storage + offset + BufferedSegmentCodec::HEADER_SIZE, payload, PAYLOAD_SIZE);
        return true;
    }

    bool peek(BufferedSegment& header, const uint8_t** payload) const {
        if (_layout.count() == 0 || payload == nullptr) return false;
        const size_t offset = _layout.frontOffset();
        header = BufferedSegmentCodec::decode(_storage + offset);
        *payload = _storage + offset + BufferedSegmentCodec::HEADER_SIZE;
        return true;
    }

    uint32_t dropOldest() {
        BufferedSegment header = {};
        const uint8_t* payload = nullptr;
        if (!peek(header, &payload)) return 0;
        _layout.pop(BufferedSegmentCodec::HEADER_SIZE + header.dataLength);
        ++_droppedSegmentCount;
        return header.segmentId;
    }

    void dequeue() {
        BufferedSegment header = {};
        const uint8_t* payload = nullptr;
        if (!peek(header, &payload)) return;
        _layout.pop(BufferedSegmentCodec::HEADER_SIZE + header.dataLength);
    }

    uint32_t droppedSegmentCount() const { return _droppedSegmentCount; }

private:
    uint8_t _storage[CAPACITY] = {};
    RingBufferLayout _layout{CAPACITY};
    uint32_t _droppedSegmentCount = 0;
};

constexpr size_t OverflowBufferFixture::CAPACITY;
constexpr size_t OverflowBufferFixture::PAYLOAD_SIZE;

void assertFront(OverflowBufferFixture& buffer, uint32_t segmentId,
                 const uint8_t* expectedPayload) {
    BufferedSegment header = {};
    const uint8_t* payload = nullptr;
    TEST_ASSERT_TRUE(buffer.peek(header, &payload));
    TEST_ASSERT_EQUAL_UINT32(segmentId, header.segmentId);
    TEST_ASSERT_EQUAL_UINT8_ARRAY(
        expectedPayload, payload, OverflowBufferFixture::PAYLOAD_SIZE);
}

void test_oldest_is_dropped_and_newest_is_stored_in_fifo_order() {
    OverflowBufferFixture buffer;
    const uint8_t payloadA[] = {1, 1, 1, 1};
    const uint8_t payloadB[] = {2, 2, 2, 2};
    const uint8_t payloadC[] = {3, 3, 3, 3};
    const uint8_t payloadD[] = {4, 4, 4, 4};

    TEST_ASSERT_TRUE(buffer.store(1, payloadA));
    TEST_ASSERT_TRUE(buffer.store(2, payloadB));
    TEST_ASSERT_TRUE(buffer.store(3, payloadC));
    TEST_ASSERT_FALSE(buffer.store(4, payloadD));

    assertFront(buffer, 1, payloadA);
    TEST_ASSERT_EQUAL_UINT32(1, buffer.dropOldest());
    TEST_ASSERT_EQUAL_UINT32(1, buffer.droppedSegmentCount());
    TEST_ASSERT_TRUE(buffer.store(4, payloadD));

    assertFront(buffer, 2, payloadB);
    buffer.dequeue();
    assertFront(buffer, 3, payloadC);
    buffer.dequeue();
    assertFront(buffer, 4, payloadD);
    TEST_ASSERT_EQUAL_UINT32(1, buffer.droppedSegmentCount());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_oldest_is_dropped_and_newest_is_stored_in_fifo_order);
    return UNITY_END();
}