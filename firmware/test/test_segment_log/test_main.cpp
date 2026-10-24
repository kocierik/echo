#include <unity.h>

#include <map>
#include <string>
#include <vector>

#include "ble_protocol.h"
#include "segment_log.h"

/** The card, in memory: whole files as byte vectors. */
class MemoryStorage : public LogStorage {
public:
    std::map<std::string, std::vector<uint8_t>> files;
    uint64_t capacity = 1ull << 30;
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
        if (failWrites) return false;
        files[path] = std::vector<uint8_t>(data, data + length);
        return true;
    }
    uint64_t freeBytes() override {
        uint64_t used = 0;
        for (auto& f : files) used += f.second.size();
        return used >= capacity ? 0 : capacity - used;
    }
};

static std::vector<uint8_t> payload(uint8_t seed, size_t length) {
    std::vector<uint8_t> data(length);
    for (size_t i = 0; i < length; ++i) data[i] = static_cast<uint8_t>(seed + i * 7);
    return data;
}

static BufferedSegment headerFor(uint32_t id, const std::vector<uint8_t>& data) {
    return {id, static_cast<uint32_t>(data.size()), 1500, 200, 1000 * id, 321,
            EchoBleProtocol::crc32(data.data(), data.size())};
}

static void append(SegmentLog& log, uint32_t id, size_t length) {
    auto data = payload(static_cast<uint8_t>(id), length);
    TEST_ASSERT_TRUE(log.append(headerFor(id, data), data.data()));
}

static uint8_t staging[4096];

static uint32_t peekId(SegmentLog& log) {
    BufferedSegment header{};
    if (!log.peek(header, staging, sizeof(staging))) return 0;
    return header.segmentId;
}

void test_segments_come_back_oldest_first_with_their_data() {
    MemoryStorage card;
    SegmentLog log(card, 1024);
    TEST_ASSERT_TRUE(log.begin());
    append(log, 1, 300);
    append(log, 2, 500);

    BufferedSegment header{};
    TEST_ASSERT_TRUE(log.peek(header, staging, sizeof(staging)));
    TEST_ASSERT_EQUAL_UINT32(1, header.segmentId);
    TEST_ASSERT_EQUAL_UINT32(300, header.dataLength);
    auto expected = payload(1, 300);
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected.data(), staging, 300);
    log.dequeue();
    TEST_ASSERT_EQUAL_UINT32(2, peekId(log));
    log.dequeue();
    TEST_ASSERT_TRUE(log.isEmpty());
    TEST_ASSERT_EQUAL_UINT32(0, peekId(log));
}

void test_files_roll_over_and_are_deleted_once_sent() {
    MemoryStorage card;
    SegmentLog log(card, 1024);  // 1 KB files: two 400-byte records each
    TEST_ASSERT_TRUE(log.begin());
    for (uint32_t id = 1; id <= 5; ++id) append(log, id, 400);
    TEST_ASSERT_TRUE(card.files.size() >= 3);  // three logs and the head

    for (uint32_t id = 1; id <= 5; ++id) {
        TEST_ASSERT_EQUAL_UINT32(id, peekId(log));
        log.dequeue();
    }
    TEST_ASSERT_TRUE(log.isEmpty());
    // Only the head file and at most the last (empty) log remain
    size_t logs = 0;
    for (auto& f : card.files) if (f.first.find(".log") != std::string::npos) ++logs;
    TEST_ASSERT_TRUE(logs <= 1);
}

void test_the_read_position_survives_a_restart() {
    MemoryStorage card;
    {
        SegmentLog log(card, 1024);
        TEST_ASSERT_TRUE(log.begin());
        for (uint32_t id = 1; id <= 4; ++id) append(log, id, 400);
        // As the transport does: look at the segment, then remove it once sent
        for (int sent = 0; sent < 3; ++sent) {
            peekId(log);
            log.dequeue();
        }
    }
    SegmentLog again(card, 1024);
    TEST_ASSERT_TRUE(again.begin());
    TEST_ASSERT_EQUAL_UINT32(4, peekId(again));
    append(again, 5, 400);
    again.dequeue();
    TEST_ASSERT_EQUAL_UINT32(5, peekId(again));
    // A remove with nothing looked at removes nothing
    SegmentLog idle(card, 1024);
    TEST_ASSERT_TRUE(idle.begin());
    idle.dequeue();
    TEST_ASSERT_EQUAL_UINT32(5, peekId(idle));
}

void test_a_half_written_record_is_skipped_not_sent() {
    MemoryStorage card;
    {
        SegmentLog log(card, 4096);
        TEST_ASSERT_TRUE(log.begin());
        append(log, 1, 300);
        append(log, 2, 300);
    }
    // Power cut while writing record 2: its last bytes never reached the card
    for (auto& f : card.files) {
        if (f.first.find(".log") != std::string::npos) f.second.resize(f.second.size() - 50);
    }
    SegmentLog again(card, 4096);
    TEST_ASSERT_TRUE(again.begin());
    TEST_ASSERT_EQUAL_UINT32(1, peekId(again));
    again.dequeue();
    TEST_ASSERT_EQUAL_UINT32(0, peekId(again));
    TEST_ASSERT_TRUE(again.isEmpty());
    // New speech after the cut is kept
    append(again, 3, 300);
    TEST_ASSERT_EQUAL_UINT32(3, peekId(again));
}

void test_corrupted_data_is_skipped() {
    MemoryStorage card;
    SegmentLog log(card, 4096);
    TEST_ASSERT_TRUE(log.begin());
    append(log, 1, 300);
    append(log, 2, 300);
    for (auto& f : card.files) {
        if (f.first.find(".log") != std::string::npos) f.second[BufferedSegmentCodec::HEADER_SIZE + 10] ^= 0xFF;
    }
    TEST_ASSERT_EQUAL_UINT32(2, peekId(log));
    TEST_ASSERT_EQUAL_UINT32(1, log.droppedSegmentCount());
}

void test_a_full_card_drops_the_oldest_file() {
    MemoryStorage card;
    card.capacity = 3000;
    SegmentLog log(card, 1024);
    TEST_ASSERT_TRUE(log.begin());
    for (uint32_t id = 1; id <= 10; ++id) append(log, id, 400);

    // The oldest went to make room; the newest are all there, in order
    TEST_ASSERT_TRUE(log.droppedSegmentCount() > 0);
    uint32_t last = 0;
    uint32_t id = 0;
    while ((id = peekId(log)) != 0) {
        TEST_ASSERT_TRUE(id > last);
        last = id;
        log.dequeue();
    }
    TEST_ASSERT_EQUAL_UINT32(10, last);
}

void test_pending_bytes_and_a_failing_card() {
    MemoryStorage card;
    SegmentLog log(card, 4096);
    TEST_ASSERT_TRUE(log.begin());
    append(log, 1, 300);
    TEST_ASSERT_EQUAL_UINT32(300 + BufferedSegmentCodec::HEADER_SIZE, log.pendingBytes());

    card.failWrites = true;
    auto data = payload(2, 300);
    TEST_ASSERT_FALSE(log.append(headerFor(2, data), data.data()));
    TEST_ASSERT_EQUAL_UINT32(1, peekId(log));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_segments_come_back_oldest_first_with_their_data);
    RUN_TEST(test_files_roll_over_and_are_deleted_once_sent);
    RUN_TEST(test_the_read_position_survives_a_restart);
    RUN_TEST(test_a_half_written_record_is_skipped_not_sent);
    RUN_TEST(test_corrupted_data_is_skipped);
    RUN_TEST(test_a_full_card_drops_the_oldest_file);
    RUN_TEST(test_pending_bytes_and_a_failing_card);
    return UNITY_END();
}
