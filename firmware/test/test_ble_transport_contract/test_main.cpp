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

void test_main_uses_ble_only_transport() {
    const std::string source = readMainSource();
    TEST_ASSERT_FALSE(source.empty());
    TEST_ASSERT_TRUE(source.find("#include <WiFi.h>") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("#include \"http_sender.h\"") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("#include \"time_sync.h\"") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("#include \"ble_transport.h\"") != std::string::npos);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_main_uses_ble_only_transport);
    return UNITY_END();
}