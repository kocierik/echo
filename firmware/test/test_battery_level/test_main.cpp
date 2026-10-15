#include <unity.h>

#include "battery_level.h"

using namespace BatteryLevel;

void test_the_divider_doubles_the_pin_voltage() {
    TEST_ASSERT_EQUAL_UINT32(3900, batteryMillivolts(1950, 2.0f));
}

void test_percent_follows_the_lipo_curve() {
    TEST_ASSERT_EQUAL_UINT8(100, percentFromMillivolts(4200));
    TEST_ASSERT_EQUAL_UINT8(100, percentFromMillivolts(4300));  // charging
    TEST_ASSERT_EQUAL_UINT8(65, percentFromMillivolts(3900));
    TEST_ASSERT_EQUAL_UINT8(85, percentFromMillivolts(4050));   // between 80 and 90
    TEST_ASSERT_EQUAL_UINT8(0, percentFromMillivolts(3300));
    TEST_ASSERT_EQUAL_UINT8(0, percentFromMillivolts(3000));
}

void test_out_of_range_readings_are_unknown() {
    TEST_ASSERT_EQUAL_UINT8(UNKNOWN, percentFromMillivolts(0));      // no divider
    TEST_ASSERT_EQUAL_UINT8(UNKNOWN, percentFromMillivolts(2000));
    TEST_ASSERT_EQUAL_UINT8(UNKNOWN, percentFromMillivolts(5000));
}

void test_the_smoother_reports_changes_only() {
    Smoother smoother;
    TEST_ASSERT_EQUAL_UINT8(UNKNOWN, smoother.percent());
    TEST_ASSERT_TRUE(smoother.add(3900));
    TEST_ASSERT_EQUAL_UINT8(65, smoother.percent());
    TEST_ASSERT_FALSE(smoother.add(3900));
    // A short dip under load moves the average a quarter of the way
    TEST_ASSERT_TRUE(smoother.add(3700));
    TEST_ASSERT_TRUE(smoother.percent() > 25 && smoother.percent() < 65);
    TEST_ASSERT_TRUE(smoother.add(0));  // divider removed
    TEST_ASSERT_EQUAL_UINT8(UNKNOWN, smoother.percent());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_the_divider_doubles_the_pin_voltage);
    RUN_TEST(test_percent_follows_the_lipo_curve);
    RUN_TEST(test_out_of_range_readings_are_unknown);
    RUN_TEST(test_the_smoother_reports_changes_only);
    return UNITY_END();
}
