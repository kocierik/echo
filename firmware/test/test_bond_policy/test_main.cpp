#include <unity.h>

#include "bond_policy.h"

void test_accepts_first_identity() {
    BondPolicy policy;

    TEST_ASSERT_TRUE(policy.accept("mobile-a"));
    TEST_ASSERT_TRUE(policy.hasPeer());
    TEST_ASSERT_EQUAL_STRING("mobile-a", policy.acceptedIdentity().c_str());
}

void test_accepts_same_identity_reconnect() {
    BondPolicy policy;
    TEST_ASSERT_TRUE(policy.accept("mobile-a"));

    TEST_ASSERT_TRUE(policy.accept("mobile-a"));
    TEST_ASSERT_EQUAL_STRING("mobile-a", policy.acceptedIdentity().c_str());
}

void test_rejects_second_identity() {
    BondPolicy policy;
    TEST_ASSERT_TRUE(policy.accept("mobile-a"));

    TEST_ASSERT_FALSE(policy.accept("mobile-b"));
    TEST_ASSERT_EQUAL_STRING("mobile-a", policy.acceptedIdentity().c_str());
}

void test_rejects_empty_identity() {
    BondPolicy policy;

    TEST_ASSERT_FALSE(policy.accept(""));
    TEST_ASSERT_FALSE(policy.hasPeer());
    TEST_ASSERT_TRUE(policy.acceptedIdentity().empty());
}

void test_restores_existing_identity() {
    BondPolicy policy;

    TEST_ASSERT_TRUE(policy.restore("mobile-a"));
    TEST_ASSERT_TRUE(policy.hasPeer());
    TEST_ASSERT_TRUE(policy.accept("mobile-a"));
    TEST_ASSERT_FALSE(policy.accept("mobile-b"));
}

void test_forget_allows_new_identity() {
    BondPolicy policy;
    TEST_ASSERT_TRUE(policy.accept("mobile-a"));

    policy.forget();

    TEST_ASSERT_FALSE(policy.hasPeer());
    TEST_ASSERT_TRUE(policy.accept("mobile-b"));
    TEST_ASSERT_EQUAL_STRING("mobile-b", policy.acceptedIdentity().c_str());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_accepts_first_identity);
    RUN_TEST(test_accepts_same_identity_reconnect);
    RUN_TEST(test_rejects_second_identity);
    RUN_TEST(test_rejects_empty_identity);
    RUN_TEST(test_restores_existing_identity);
    RUN_TEST(test_forget_allows_new_identity);
    return UNITY_END();
}