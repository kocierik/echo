#include <unity.h>

#include <fstream>
#include <sstream>
#include <string>

std::string readMainSource() {
    std::ifstream stream("src/main.ino");
    std::ostringstream contents;
    contents << stream.rdbuf();
    return contents.str();
}

std::string readSource(const char* path) {
    std::ifstream stream(path);
    std::ostringstream contents;
    contents << stream.rdbuf();
    return contents.str();
}

size_t countOccurrences(const std::string& source, const std::string& value) {
    size_t count = 0;
    size_t position = 0;
    while ((position = source.find(value, position)) != std::string::npos) {
        ++count;
        position += value.size();
    }
    return count;
}

void test_main_uses_ble_only_transport() {
    const std::string source = readMainSource();
    TEST_ASSERT_FALSE(source.empty());
    TEST_ASSERT_TRUE(source.find("#include <WiFi.h>") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("#include \"http_sender.h\"") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("#include \"time_sync.h\"") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("#include \"ble_transport.h\"") != std::string::npos);
}

void test_crc_is_accumulated_during_encoding_and_not_scanned_by_transport() {
    const std::string mainSource = readMainSource();
    const std::string transportSource = readSource("src/ble_transport.h");
    const std::string bufferSource = readSource("src/buffered_segment.h");

    TEST_ASSERT_TRUE(mainSource.find("crc32Update") != std::string::npos);
    TEST_ASSERT_TRUE(mainSource.find("crc32Finalize") != std::string::npos);
    TEST_ASSERT_TRUE(bufferSource.find("uint32_t crc") != std::string::npos);
    TEST_ASSERT_TRUE(transportSource.find("_segment.crc") != std::string::npos);
    TEST_ASSERT_TRUE(transportSource.find("_crcOffset") == std::string::npos);
    TEST_ASSERT_TRUE(transportSource.find("CRC_BYTES_PER_UPDATE") == std::string::npos);
    TEST_ASSERT_TRUE(transportSource.find("updateActiveCrc") == std::string::npos);
}

void test_firmware_uses_approved_latency_constants() {
    const std::string configSource = readSource("src/config.h");
    const std::string stateSource = readSource("src/ble_transfer_state.h");

    TEST_ASSERT_TRUE(configSource.find("SEGMENT_DURATION_MS 6000") != std::string::npos);
    TEST_ASSERT_TRUE(configSource.find("VAD_SPEECH_END_FRAMES 25") != std::string::npos);
    TEST_ASSERT_TRUE(configSource.find("BLE_PREFERRED_MTU 247") != std::string::npos);
    TEST_ASSERT_TRUE(stateSource.find("WINDOW_SIZE = 32") != std::string::npos);
    TEST_ASSERT_TRUE(stateSource.find("BURST_BUDGET_US = 3000") != std::string::npos);
}

void test_vad_trigger_frame_is_not_encoded_after_prebuffer_replay() {
    const std::string source = readMainSource();
    TEST_ASSERT_TRUE(source.find("preBufferCount - 1") != std::string::npos);
}

void test_muting_only_finalizes_the_live_segment() {
    const std::string source = readMainSource();
    const size_t muteBlockStart = source.find("if (muted)");
    const size_t audioRead = source.find("audio.readSamples", muteBlockStart);

    TEST_ASSERT_TRUE(muteBlockStart != std::string::npos);
    TEST_ASSERT_TRUE(audioRead != std::string::npos);
    const std::string muteBlock = source.substr(muteBlockStart, audioRead - muteBlockStart);
    TEST_ASSERT_TRUE(muteBlock.find("finalizeSegment()") != std::string::npos);
    TEST_ASSERT_TRUE(muteBlock.find("encoder.reset()") == std::string::npos);
    TEST_ASSERT_TRUE(muteBlock.find("segmentBuffer") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("_testSegmentInjected") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("framesToGenerate") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("Stored TEST segment") == std::string::npos);
}

void test_transport_gates_each_notification_at_the_deadline() {
    const std::string source = readSource("src/ble_transport.h");

    TEST_ASSERT_TRUE(source.find("const uint32_t deadlineUs =") != std::string::npos);
    TEST_ASSERT_TRUE(source.find("notifyAudio(const uint8_t* data, size_t length, uint32_t deadlineUs)") !=
                     std::string::npos);
    TEST_ASSERT_TRUE(source.find("notifyBufferStatus(const PSRAMBuffer& buffer, uint32_t deadlineUs)") !=
                     std::string::npos);
    TEST_ASSERT_EQUAL_UINT32(1, countOccurrences(source, "_audioCharacteristic->notify("));
    TEST_ASSERT_EQUAL_UINT32(1, countOccurrences(source, "_controlCharacteristic->notify("));
    TEST_ASSERT_TRUE(source.find(
        "if (!beforeBurstDeadline(deadlineUs)) return false;\n"
        "        const bool ok = _audioCharacteristic->notify") != std::string::npos);
    TEST_ASSERT_TRUE(source.find(
        "if (!beforeBurstDeadline(deadlineUs)) return false;\n"
        "        return _controlCharacteristic->notify") != std::string::npos);
}

void test_indicator_uses_named_active_low_led_values() {
    const std::string source = readSource("src/indicators.h");
    TEST_ASSERT_TRUE(source.find("LED_ON = LOW") != std::string::npos);
    TEST_ASSERT_TRUE(source.find("LED_OFF = HIGH") != std::string::npos);
    TEST_ASSERT_TRUE(source.find("active ? LED_ON : LED_OFF") != std::string::npos);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_main_uses_ble_only_transport);
    RUN_TEST(test_crc_is_accumulated_during_encoding_and_not_scanned_by_transport);
    RUN_TEST(test_firmware_uses_approved_latency_constants);
    RUN_TEST(test_vad_trigger_frame_is_not_encoded_after_prebuffer_replay);
    RUN_TEST(test_muting_only_finalizes_the_live_segment);
    RUN_TEST(test_transport_gates_each_notification_at_the_deadline);
    RUN_TEST(test_indicator_uses_named_active_low_led_values);
    return UNITY_END();
}