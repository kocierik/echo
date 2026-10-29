#include <uECC.h>
#include <unity.h>

#include <cstdio>
#include <string>
#include <vector>

#include "ota_health.h"
#include "ota_receiver.h"
#include "ota_signature.h"
#include "sha256.h"

using namespace EchoBleProtocol;

static std::string hex(const uint8_t* bytes, size_t length) {
    std::string out;
    char pair[3];
    for (size_t index = 0; index < length; ++index) {
        snprintf(pair, sizeof(pair), "%02x", bytes[index]);
        out += pair;
    }
    return out;
}

static std::string sha256Hex(const std::vector<uint8_t>& data, size_t chunk) {
    Sha256 hash;
    for (size_t offset = 0; offset < data.size(); offset += chunk) {
        const size_t length = data.size() - offset < chunk ? data.size() - offset : chunk;
        hash.update(data.data() + offset, length);
    }
    uint8_t digest[Sha256::DIGEST_SIZE];
    hash.finish(digest);
    return hex(digest, sizeof(digest));
}

static std::vector<uint8_t> bytesOf(const char* text) {
    return std::vector<uint8_t>(text, text + strlen(text));
}

void test_sha256_known_vectors() {
    TEST_ASSERT_EQUAL_STRING(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        sha256Hex({}, 1).c_str());
    TEST_ASSERT_EQUAL_STRING(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        sha256Hex(bytesOf("abc"), 64).c_str());
    // 56 bytes: the length no longer fits in the first block
    TEST_ASSERT_EQUAL_STRING(
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        sha256Hex(bytesOf("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"), 7).c_str());
}

void test_sha256_a_million_bytes_in_uneven_chunks() {
    const std::vector<uint8_t> data(1000000, 'a');
    const std::string expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0";
    TEST_ASSERT_EQUAL_STRING(expected.c_str(), sha256Hex(data, 241).c_str());
    TEST_ASSERT_EQUAL_STRING(expected.c_str(), sha256Hex(data, 1000000).c_str());
}

class FakeFlash : public OtaFlash {
public:
    uint32_t capacity() const override { return capacityBytes; }
    bool begin(uint32_t size) override {
        ++begins;
        written.clear();
        open = beginOk;
        expectedSize = size;
        return beginOk;
    }
    bool write(const uint8_t* data, size_t length) override {
        if (!open || failWriteAt == written.size()) return false;
        written.insert(written.end(), data, data + length);
        return true;
    }
    bool finish() override {
        open = false;
        finished = finishOk;
        return finishOk;
    }
    void abort() override {
        if (open) ++aborts;
        open = false;
    }

    uint32_t capacityBytes = 4096;
    bool beginOk = true;
    bool finishOk = true;
    size_t failWriteAt = SIZE_MAX;
    std::vector<uint8_t> written;
    uint32_t expectedSize = 0;
    int begins = 0;
    int aborts = 0;
    bool open = false;
    bool finished = false;
};

static std::vector<uint8_t> image(size_t size) {
    std::vector<uint8_t> data(size);
    for (size_t index = 0; index < size; ++index) data[index] = static_cast<uint8_t>(index * 7);
    return data;
}

static void digestOf(const std::vector<uint8_t>& data, uint8_t* digest) {
    Sha256 hash;
    hash.update(data.data(), data.size());
    hash.finish(digest);
}

// A release key made for the tests, and the signature the release script would give
struct TestKey {
    uint8_t publicKey[OTA_PUBLIC_KEY_SIZE];
    uint8_t privateKey[32];
};

static const TestKey& makeKey(TestKey& key) {
    TEST_ASSERT_EQUAL(1, uECC_make_key(key.publicKey, key.privateKey, uECC_secp256r1()));
    return key;
}

static const TestKey& releaseKey() {
    static TestKey key;
    static const TestKey& made = makeKey(key);
    return made;
}

static const uint8_t* signatureFor(const uint8_t* digest, const TestKey& key = releaseKey()) {
    static uint8_t signature[OTA_SIGNATURE_SIZE];
    TEST_ASSERT_EQUAL(1, uECC_sign(key.privateKey, digest, SHA256_SIZE, signature,
                                   uECC_secp256r1()));
    return signature;
}

static void fromHex(const char* text, uint8_t* out, size_t length) {
    for (size_t index = 0; index < length; ++index) {
        unsigned value = 0;
        sscanf(text + index * 2, "%2x", &value);
        out[index] = static_cast<uint8_t>(value);
    }
}

static uint8_t sendAll(OtaReceiver& receiver, const std::vector<uint8_t>& data, size_t chunk) {
    for (size_t offset = 0; offset < data.size(); offset += chunk) {
        const size_t length = data.size() - offset < chunk ? data.size() - offset : chunk;
        const uint8_t error = receiver.write(static_cast<uint32_t>(offset), data.data() + offset, length);
        if (error != OTA_ERROR_NONE) return error;
    }
    return OTA_ERROR_NONE;
}

void test_a_complete_identical_image_is_written_and_made_bootable() {
    FakeFlash flash;
    OtaReceiver receiver(flash, releaseKey().publicKey);
    const std::vector<uint8_t> data = image(1000);
    uint8_t digest[32];
    digestOf(data, digest);

    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_NONE, receiver.begin(1000, digest, signatureFor(digest)));
    TEST_ASSERT_EQUAL(OtaReceiver::State::RECEIVING, receiver.state());
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_NONE, sendAll(receiver, data, 182));

    TEST_ASSERT_EQUAL(OtaReceiver::State::DONE, receiver.state());
    TEST_ASSERT_TRUE(flash.finished);
    TEST_ASSERT_EQUAL_UINT32(1000, receiver.received());
    TEST_ASSERT_TRUE(data == flash.written);
}

void test_a_different_image_is_never_made_bootable() {
    FakeFlash flash;
    OtaReceiver receiver(flash, releaseKey().publicKey);
    std::vector<uint8_t> data = image(500);
    uint8_t digest[32];
    digestOf(data, digest);
    data[321] ^= 0x01;  // one bit changed on the way

    receiver.begin(500, digest, signatureFor(digest));
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_HASH_MISMATCH, sendAll(receiver, data, 100));
    TEST_ASSERT_EQUAL(OtaReceiver::State::FAILED, receiver.state());
    TEST_ASSERT_FALSE(flash.finished);
    TEST_ASSERT_EQUAL(1, flash.aborts);
}

void test_too_large_or_empty_images_are_refused_before_writing() {
    FakeFlash flash;
    OtaReceiver receiver(flash, releaseKey().publicKey);
    const uint8_t digest[32] = {};
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_TOO_LARGE, receiver.begin(4097, digest, signatureFor(digest)));
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_TOO_LARGE, receiver.begin(0, digest, signatureFor(digest)));
    TEST_ASSERT_EQUAL(0, flash.begins);

    flash.beginOk = false;
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_FLASH, receiver.begin(10, digest, signatureFor(digest)));
    TEST_ASSERT_EQUAL(OtaReceiver::State::FAILED, receiver.state());
}

void test_a_gap_or_an_overrun_fails_but_a_repeated_chunk_is_ignored() {
    FakeFlash flash;
    OtaReceiver receiver(flash, releaseKey().publicKey);
    const std::vector<uint8_t> data = image(300);
    uint8_t digest[32];
    digestOf(data, digest);

    receiver.begin(300, digest, signatureFor(digest));
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_NONE, receiver.write(0, data.data(), 100));
    // The app retried a write that had arrived: nothing happens
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_NONE, receiver.write(0, data.data(), 100));
    TEST_ASSERT_EQUAL_UINT32(100, receiver.received());
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_OUT_OF_ORDER, receiver.write(150, data.data() + 150, 50));
    TEST_ASSERT_EQUAL(OtaReceiver::State::FAILED, receiver.state());
    TEST_ASSERT_EQUAL(1, flash.aborts);

    receiver.begin(300, digest, signatureFor(digest));
    receiver.write(0, data.data(), 250);
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_OUT_OF_ORDER, receiver.write(250, data.data(), 100));

    receiver.begin(300, digest, signatureFor(digest));
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_OUT_OF_ORDER, receiver.write(0, nullptr, 0));
}

void test_flash_failures_are_reported() {
    FakeFlash flash;
    OtaReceiver receiver(flash, releaseKey().publicKey);
    const std::vector<uint8_t> data = image(300);
    uint8_t digest[32];
    digestOf(data, digest);

    flash.failWriteAt = 200;
    receiver.begin(300, digest, signatureFor(digest));
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_FLASH, sendAll(receiver, data, 100));

    flash.failWriteAt = SIZE_MAX;
    flash.finishOk = false;  // e.g. not an ESP32-S3 image
    receiver.begin(300, digest, signatureFor(digest));
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_INVALID_IMAGE, sendAll(receiver, data, 100));
    TEST_ASSERT_EQUAL(OtaReceiver::State::FAILED, receiver.state());
}

void test_abort_and_a_new_begin_start_over() {
    FakeFlash flash;
    OtaReceiver receiver(flash, releaseKey().publicKey);
    const std::vector<uint8_t> data = image(300);
    uint8_t digest[32];
    digestOf(data, digest);

    receiver.begin(300, digest, signatureFor(digest));
    receiver.write(0, data.data(), 100);
    receiver.abort();
    TEST_ASSERT_EQUAL(OtaReceiver::State::IDLE, receiver.state());
    TEST_ASSERT_EQUAL(1, flash.aborts);
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_NOT_STARTED, receiver.write(100, data.data(), 100));

    receiver.begin(300, digest, signatureFor(digest));
    receiver.write(0, data.data(), 100);
    receiver.begin(300, digest, signatureFor(digest));  // the app started again: from 0
    TEST_ASSERT_EQUAL(2, flash.aborts);
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_NONE, sendAll(receiver, data, 64));
    TEST_ASSERT_EQUAL(OtaReceiver::State::DONE, receiver.state());
}

void test_an_image_signed_with_another_key_is_refused_before_writing() {
    FakeFlash flash;
    OtaReceiver receiver(flash, releaseKey().publicKey);
    const std::vector<uint8_t> data = image(300);
    uint8_t digest[32];
    digestOf(data, digest);
    TestKey other;
    makeKey(other);

    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_BAD_SIGNATURE,
                            receiver.begin(300, digest, signatureFor(digest, other)));
    TEST_ASSERT_EQUAL(OtaReceiver::State::FAILED, receiver.state());
    TEST_ASSERT_EQUAL(0, flash.begins);
    TEST_ASSERT_EQUAL_UINT8(OTA_ERROR_NOT_STARTED, receiver.write(0, data.data(), 100));
}

void test_a_signature_made_with_openssl_is_accepted() {
    // openssl dgst -sha256 -sign over "echo firmware", the DER signature as raw r||s: what
    // scripts/firmware-release.sh and the server give the app
    uint8_t publicKey[OTA_PUBLIC_KEY_SIZE];
    uint8_t signature[OTA_SIGNATURE_SIZE];
    fromHex("f30e77270e3bd0c8b46414bc60bf4966474ee8582e56016003bcfad6912759ba"
            "ca174c10dd4a28f4a4c38a93fe8a95881922fd5cc026a18ffbf700b579f3d617",
            publicKey, sizeof(publicKey));
    fromHex("34575f6dfcd8775b61b0a722b9a85f2289e795c2bbcb14cbfe396d80f68430f9"
            "d97051d4885477b8fc44470be5b9d63d682cc55f1beefdec567398e9597bf0ca",
            signature, sizeof(signature));
    uint8_t digest[32];
    digestOf(bytesOf("echo firmware"), digest);

    TEST_ASSERT_TRUE(otaSignatureValid(publicKey, digest, signature));
    digest[0] ^= 0x01;
    TEST_ASSERT_FALSE(otaSignatureValid(publicKey, digest, signature));
}

void test_a_new_firmware_is_kept_once_the_app_talks_to_it() {
    OtaHealthCheck check(300000);
    check.begin(true, 1000);
    TEST_ASSERT_EQUAL(OtaHealthCheck::Decision::NONE, check.update(false, 200000));
    TEST_ASSERT_EQUAL(OtaHealthCheck::Decision::KEEP, check.update(true, 200001));
    TEST_ASSERT_FALSE(check.onTrial());
    TEST_ASSERT_EQUAL(OtaHealthCheck::Decision::NONE, check.update(false, 900000));
}

void test_a_new_firmware_the_app_never_reaches_rolls_back() {
    OtaHealthCheck check(300000);
    const uint32_t start = 0xFFFF0000U;  // millis() wraps
    check.begin(true, start);
    TEST_ASSERT_EQUAL(OtaHealthCheck::Decision::NONE, check.update(false, start + 299999));
    TEST_ASSERT_EQUAL(OtaHealthCheck::Decision::ROLL_BACK, check.update(false, start + 300000));
    TEST_ASSERT_EQUAL(OtaHealthCheck::Decision::NONE, check.update(true, start + 300001));
}

void test_a_normal_boot_is_never_judged() {
    OtaHealthCheck check(300000);
    check.begin(false, 0);
    TEST_ASSERT_EQUAL(OtaHealthCheck::Decision::NONE, check.update(false, 999999));
    TEST_ASSERT_EQUAL(OtaHealthCheck::Decision::NONE, check.update(true, 1000000));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_sha256_known_vectors);
    RUN_TEST(test_sha256_a_million_bytes_in_uneven_chunks);
    RUN_TEST(test_a_complete_identical_image_is_written_and_made_bootable);
    RUN_TEST(test_a_different_image_is_never_made_bootable);
    RUN_TEST(test_too_large_or_empty_images_are_refused_before_writing);
    RUN_TEST(test_a_gap_or_an_overrun_fails_but_a_repeated_chunk_is_ignored);
    RUN_TEST(test_flash_failures_are_reported);
    RUN_TEST(test_abort_and_a_new_begin_start_over);
    RUN_TEST(test_an_image_signed_with_another_key_is_refused_before_writing);
    RUN_TEST(test_a_signature_made_with_openssl_is_accepted);
    RUN_TEST(test_a_new_firmware_is_kept_once_the_app_talks_to_it);
    RUN_TEST(test_a_new_firmware_the_app_never_reaches_rolls_back);
    RUN_TEST(test_a_normal_boot_is_never_judged);
    return UNITY_END();
}
