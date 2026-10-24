#include <unity.h>

#include <deque>
#include <map>
#include <string>
#include <vector>

#include "ble_protocol.h"
#include "tiered_queue.h"

/** The PSRAM queue, in memory: holds at most `capacity` bytes of data. */
class FakeHot {
public:
    explicit FakeHot(size_t capacity) : _capacity(capacity) {}

    bool store(uint32_t id, const uint8_t* data, size_t length, uint32_t durationMs,
               uint32_t silenceBeforeMs, uint32_t capturedAtMs, uint16_t avgEnergy,
               uint32_t crc) {
        if (!hasSpace(length)) return false;
        _items.push_back({{id, static_cast<uint32_t>(length), durationMs, silenceBeforeMs,
                           capturedAtMs, avgEnergy, crc},
                          std::vector<uint8_t>(data, data + length)});
        return true;
    }
    bool hasSpace(size_t length) const { return bytesUsed() + length <= _capacity; }
    bool peek(BufferedSegment& header, const uint8_t** data) {
        if (_items.empty()) return false;
        header = _items.front().first;
        *data = _items.front().second.data();
        return true;
    }
    void dequeue() { if (!_items.empty()) _items.pop_front(); }
    uint32_t dropOldest() {
        if (_items.empty()) return 0;
        const uint32_t id = _items.front().first.segmentId;
        _items.pop_front();
        ++_dropped;
        return id;
    }
    uint16_t count() const { return static_cast<uint16_t>(_items.size()); }
    size_t bytesUsed() const {
        size_t used = 0;
        for (auto& item : _items) used += item.second.size();
        return used;
    }
    uint32_t droppedSegmentCount() const { return _dropped; }

private:
    size_t _capacity;
    std::deque<std::pair<BufferedSegment, std::vector<uint8_t>>> _items;
    uint32_t _dropped = 0;
};

class MemoryStorage : public LogStorage {
public:
    std::map<std::string, std::vector<uint8_t>> files;
    bool failWrites = false;
    bool append(const char* path, const uint8_t* data, size_t length) override {
        if (failWrites) return false;
        auto& file = files[path];
        file.insert(file.end(), data, data + length);
        return true;
    }
    long size(const char* path) override {
        auto it = files.find(path);
        return it == files.end() ? -1 : static_cast<long>(it->second.size());
    }
    size_t read(const char* path, size_t offset, uint8_t* out, size_t length) override {
        auto it = files.find(path);
        if (it == files.end() || offset >= it->second.size()) return 0;
        const size_t n = std::min(length, it->second.size() - offset);
        memcpy(out, it->second.data() + offset, n);
        return n;
    }
    bool remove(const char* path) override { return files.erase(path) > 0; }
    bool replace(const char* path, const uint8_t* data, size_t length) override {
        files[path] = std::vector<uint8_t>(data, data + length);
        return true;
    }
    uint64_t freeBytes() override { return 1ull << 30; }
};

static std::vector<uint8_t> payload(uint32_t id) {
    std::vector<uint8_t> data(100);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<uint8_t>(id * 31 + i);
    return data;
}

template <typename Queue>
static bool storeSegment(Queue& queue, uint32_t id) {
    auto data = payload(id);
    return queue.store(id, data.data(), data.size(), 1000, 0, id * 10, 5,
                       EchoBleProtocol::crc32(data.data(), data.size()));
}

template <typename Queue>
static std::vector<uint32_t> drain(Queue& queue) {
    std::vector<uint32_t> order;
    BufferedSegment header{};
    const uint8_t* data = nullptr;
    while (queue.peek(header, &data)) {
        auto expected = payload(header.segmentId);
        TEST_ASSERT_EQUAL_UINT8_ARRAY(expected.data(), data, expected.size());
        order.push_back(header.segmentId);
        queue.dequeue();
    }
    return order;
}

static uint8_t staging[1024];
static std::vector<uint32_t> moved;

void test_without_a_card_a_full_queue_refuses_as_today() {
    FakeHot hot(300);
    TieredQueue<FakeHot> queue(hot);
    TEST_ASSERT_TRUE(storeSegment(queue, 1));
    TEST_ASSERT_TRUE(storeSegment(queue, 2));
    TEST_ASSERT_TRUE(storeSegment(queue, 3));
    TEST_ASSERT_FALSE(storeSegment(queue, 4));
    TEST_ASSERT_EQUAL_UINT16(3, queue.count());
}

void test_with_a_card_the_oldest_moves_there_and_nothing_is_lost() {
    FakeHot hot(300);  // three segments
    MemoryStorage card;
    SegmentLog log(card, 4096);
    TEST_ASSERT_TRUE(log.begin());
    TieredQueue<FakeHot> queue(hot);
    moved.clear();
    queue.attachCard(&log, staging, sizeof(staging), [](uint32_t id) { moved.push_back(id); });

    for (uint32_t id = 1; id <= 7; ++id) TEST_ASSERT_TRUE(storeSegment(queue, id));

    // The four oldest went to the card, each announced before moving
    TEST_ASSERT_EQUAL_UINT32(4, moved.size());
    TEST_ASSERT_EQUAL_UINT32(1, moved.front());
    TEST_ASSERT_EQUAL_UINT16(3, hot.count());
    TEST_ASSERT_TRUE(queue.count() >= 4);
    TEST_ASSERT_EQUAL_UINT32(700 + 4 * BufferedSegmentCodec::HEADER_SIZE, queue.bytesUsed());

    // Sent oldest first: the card, then PSRAM
    std::vector<uint32_t> order = drain(queue);
    std::vector<uint32_t> expected = {1, 2, 3, 4, 5, 6, 7};
    TEST_ASSERT_EQUAL_UINT32(expected.size(), order.size());
    for (size_t i = 0; i < expected.size(); ++i) TEST_ASSERT_EQUAL_UINT32(expected[i], order[i]);
    TEST_ASSERT_EQUAL_UINT32(0, queue.droppedSegmentCount());
}

void test_a_failing_card_falls_back_to_dropping() {
    FakeHot hot(300);
    MemoryStorage card;
    SegmentLog log(card, 4096);
    TEST_ASSERT_TRUE(log.begin());
    TieredQueue<FakeHot> queue(hot);
    queue.attachCard(&log, staging, sizeof(staging), nullptr);
    for (uint32_t id = 1; id <= 3; ++id) TEST_ASSERT_TRUE(storeSegment(queue, id));

    card.failWrites = true;
    // Not stored: main drops the oldest, as without a card
    TEST_ASSERT_FALSE(storeSegment(queue, 4));
    TEST_ASSERT_EQUAL_UINT32(1, queue.dropOldest());
    TEST_ASSERT_TRUE(storeSegment(queue, 4));
    TEST_ASSERT_EQUAL_UINT32(1, queue.droppedSegmentCount());
}

void test_a_segment_peeked_again_is_the_same_one() {
    FakeHot hot(100);
    MemoryStorage card;
    SegmentLog log(card, 4096);
    TEST_ASSERT_TRUE(log.begin());
    TieredQueue<FakeHot> queue(hot);
    queue.attachCard(&log, staging, sizeof(staging), nullptr);
    TEST_ASSERT_TRUE(storeSegment(queue, 1));
    TEST_ASSERT_TRUE(storeSegment(queue, 2));  // 1 goes to the card

    // The transport peeks to send, then again to accept the upload
    BufferedSegment first{};
    BufferedSegment again{};
    const uint8_t* data = nullptr;
    TEST_ASSERT_TRUE(queue.peek(first, &data));
    TEST_ASSERT_TRUE(queue.peek(again, &data));
    TEST_ASSERT_EQUAL_UINT32(first.segmentId, again.segmentId);
    queue.dequeue();
    TEST_ASSERT_TRUE(queue.peek(again, &data));
    TEST_ASSERT_EQUAL_UINT32(2, again.segmentId);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_without_a_card_a_full_queue_refuses_as_today);
    RUN_TEST(test_with_a_card_the_oldest_moves_there_and_nothing_is_lost);
    RUN_TEST(test_a_failing_card_falls_back_to_dropping);
    RUN_TEST(test_a_segment_peeked_again_is_the_same_one);
    return UNITY_END();
}
