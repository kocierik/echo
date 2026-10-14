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
    TEST_ASSERT_TRUE(configSource.find("VAD_ENERGY_THRESHOLD 500") != std::string::npos);
    TEST_ASSERT_TRUE(configSource.find("BLE_PREFERRED_MTU 247") != std::string::npos);
    TEST_ASSERT_TRUE(stateSource.find("WINDOW_SIZE = 32") != std::string::npos);
    TEST_ASSERT_TRUE(stateSource.find("BURST_BUDGET_US = 3000") != std::string::npos);
    TEST_ASSERT_TRUE(stateSource.find("MAX_NOTIFICATIONS_PER_UPDATE = 4") != std::string::npos);
}

void test_transport_waits_for_ready_and_configures_ios_connection() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t readyGate = source.find("!_state.isReady()");
    const size_t peek = source.find("buffer.peek(_segment, &_segmentData)");

    TEST_ASSERT_TRUE(readyGate != std::string::npos);
    TEST_ASSERT_TRUE(peek != std::string::npos);
    TEST_ASSERT_TRUE(readyGate < peek);
    // Requesting conn param/DLE updates synchronously in onConnect races iOS's
    // own MTU exchange and causes BLE_ERR_CONN_SPVN_TMO; must not return.
    TEST_ASSERT_TRUE(source.find("updateConnParams(") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("setDataLen(") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("advertiseOnDisconnect(true)") == std::string::npos);

    const size_t notificationCounter = source.find("uint8_t notificationsSent = 0");
    const size_t statusNotification = source.find("_pendingStatus.shouldNotify");
    const size_t audioLoop = source.find("do {", statusNotification);
    TEST_ASSERT_TRUE(notificationCounter < statusNotification);
    TEST_ASSERT_TRUE(statusNotification < audioLoop);
    TEST_ASSERT_EQUAL_UINT32(
        2, countOccurrences(source, "if (notified) ++notificationsSent;"));
}

void test_nimble_callbacks_avoid_serial_io_on_the_host_task() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t serverCallbacksStart = source.find("class ServerCallbacks");
    const size_t controlCallbacksStart = source.find("class ControlCallbacks");
    const size_t controlCallbacksEnd = source.find("size_t payloadSizeForMtu", controlCallbacksStart);

    TEST_ASSERT_TRUE(serverCallbacksStart != std::string::npos);
    TEST_ASSERT_TRUE(controlCallbacksStart != std::string::npos);
    TEST_ASSERT_TRUE(controlCallbacksEnd != std::string::npos);

    const std::string serverCallbacksBody =
        source.substr(serverCallbacksStart, controlCallbacksStart - serverCallbacksStart);
    const std::string controlCallbacksBody =
        source.substr(controlCallbacksStart, controlCallbacksEnd - controlCallbacksStart);

    // A blocked USB CDC write inside a host-task callback can stall the NimBLE
    // host long enough to miss the supervision timeout window; log elsewhere.
    TEST_ASSERT_TRUE(serverCallbacksBody.find("Serial.") == std::string::npos);
    TEST_ASSERT_TRUE(controlCallbacksBody.find("Serial.") == std::string::npos);
}

void test_security_is_configured_before_server_creation() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t init = source.find("NimBLEDevice::init(BLE_DEVICE_NAME)");
    const size_t auth = source.find("NimBLEDevice::setSecurityAuth(true, false, true)");
    const size_t io = source.find("NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT)");
    const size_t restore = source.find("restoreBondPolicy()");
    const size_t createServer = source.find("NimBLEDevice::createServer()");

    TEST_ASSERT_TRUE(source.find(
        "NimBLEDevice::init(BLE_DEVICE_NAME);\n"
        "        NimBLEDevice::setSecurityAuth(true, false, true);") != std::string::npos);
    TEST_ASSERT_TRUE(init < auth);
    TEST_ASSERT_TRUE(auth < io);
    TEST_ASSERT_TRUE(io < restore);
    TEST_ASSERT_TRUE(restore < createServer);
}

void test_gatt_characteristics_require_encryption() {
    const std::string source = readSource("src/ble_transport.h");
    TEST_ASSERT_TRUE(source.find(
        "NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::NOTIFY") !=
        std::string::npos);
    TEST_ASSERT_TRUE(source.find(
        "NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC |\n"
        "            NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC |\n"
        "            NIMBLE_PROPERTY::NOTIFY") != std::string::npos);
}

void test_connect_starts_security_and_waits_for_authentication() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t connectStart = source.find("void onConnect(");
    const size_t connectEnd = source.find("void onDisconnect(", connectStart);
    TEST_ASSERT_TRUE(connectStart != std::string::npos);
    TEST_ASSERT_TRUE(connectEnd != std::string::npos);
    const std::string connectBody = source.substr(connectStart, connectEnd - connectStart);

    TEST_ASSERT_TRUE(connectBody.find("connInfo.getConnHandle()") != std::string::npos);
    TEST_ASSERT_TRUE(connectBody.find("NimBLEDevice::startSecurity(") != std::string::npos);
    TEST_ASSERT_TRUE(connectBody.find("disconnect(") != std::string::npos);
    TEST_ASSERT_TRUE(connectBody.find("BleTransportEvent::connected") == std::string::npos);
}

void test_mtu_exchange_can_complete_before_authentication() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t connectedStart = source.find("case BleTransportEventType::CONNECTED:");
    const size_t mtuStart = source.find("case BleTransportEventType::MTU_CHANGED:", connectedStart);
    const size_t controlStart = source.find("case BleTransportEventType::CONTROL:", mtuStart);
    const std::string connectedBody = source.substr(connectedStart, mtuStart - connectedStart);
    const std::string mtuBody = source.substr(mtuStart, controlStart - mtuStart);

    TEST_ASSERT_TRUE(connectedBody.find("_negotiatedMtu = 23") == std::string::npos);
    TEST_ASSERT_TRUE(mtuBody.find("_negotiatedMtu = event.mtu") != std::string::npos);
    TEST_ASSERT_TRUE(mtuBody.find("if (_connected)") == std::string::npos);
}

void test_authentication_requires_encrypted_bonded_accepted_identity() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t authStart = source.find("void onAuthenticationComplete(");
    const size_t callbacksEnd = source.find("private:", authStart);
    TEST_ASSERT_TRUE(authStart != std::string::npos);
    TEST_ASSERT_TRUE(callbacksEnd != std::string::npos);
    const std::string authBody = source.substr(authStart, callbacksEnd - authStart);

    TEST_ASSERT_TRUE(authBody.find("connInfo.isEncrypted()") != std::string::npos);
    TEST_ASSERT_TRUE(authBody.find("connInfo.isBonded()") != std::string::npos);
    TEST_ASSERT_TRUE(authBody.find("connInfo.getIdAddress().toString()") != std::string::npos);
    TEST_ASSERT_TRUE(authBody.find("_bondPolicy.accept(") != std::string::npos);
    TEST_ASSERT_TRUE(authBody.find("NimBLEDevice::deleteBond(") != std::string::npos);
    TEST_ASSERT_TRUE(authBody.find("disconnect(") != std::string::npos);
    TEST_ASSERT_TRUE(authBody.find("BleTransportEvent::connected(connInfo.getConnHandle())") !=
                     std::string::npos);
    const size_t encrypted = authBody.find("connInfo.isEncrypted()");
    const size_t bonded = authBody.find("connInfo.isBonded()");
    const size_t policy = authBody.find("_bondPolicy.accept(");
    const size_t connected = authBody.find("BleTransportEvent::connected(");
    TEST_ASSERT_TRUE(encrypted < policy);
    TEST_ASSERT_TRUE(bonded < policy);
    TEST_ASSERT_TRUE(policy < connected);
}

void test_existing_bonds_restore_one_peer_and_remove_extras() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t restoreStart = source.find("void restoreBondPolicy() {");
    const size_t restoreEnd = source.find("size_t payloadSizeForMtu", restoreStart);
    TEST_ASSERT_TRUE(restoreStart != std::string::npos);
    TEST_ASSERT_TRUE(restoreEnd != std::string::npos);
    const std::string restoreBody = source.substr(restoreStart, restoreEnd - restoreStart);

    TEST_ASSERT_TRUE(restoreBody.find("NimBLEDevice::getNumBonds()") != std::string::npos);
    TEST_ASSERT_TRUE(restoreBody.find("NimBLEDevice::getBondedAddress(0).toString()") !=
                     std::string::npos);
    TEST_ASSERT_TRUE(restoreBody.find("_bondPolicy.restore(") != std::string::npos);
    TEST_ASSERT_TRUE(restoreBody.find("NimBLEDevice::getBondedAddress(1)") != std::string::npos);
    TEST_ASSERT_TRUE(restoreBody.find("NimBLEDevice::deleteBond(") != std::string::npos);
    TEST_ASSERT_TRUE(restoreBody.find("break") != std::string::npos);
}

void test_forget_bond_ack_precedes_store_deletion_and_disconnect() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t forgetStart = source.find("bool processPendingForgetBond(");
    const size_t forgetEnd = source.find("bool notifyBufferStatus", forgetStart);
    TEST_ASSERT_TRUE(forgetStart != std::string::npos);
    TEST_ASSERT_TRUE(forgetEnd != std::string::npos);
    const std::string forgetBody = source.substr(forgetStart, forgetEnd - forgetStart);

    const size_t frame = forgetBody.find("EchoBleProtocol::FRAME_FORGET_BOND_OK");
    const size_t notify = forgetBody.find("_controlCharacteristic->notify(");
    const size_t clear = forgetBody.find("_bondPolicy.forget()");
    const size_t deleteBonds = forgetBody.find("NimBLEDevice::deleteAllBonds()");
    const size_t disconnect = forgetBody.find("_server->disconnect(_connectionHandle)");
    TEST_ASSERT_TRUE(frame < notify);
    TEST_ASSERT_TRUE(notify < clear);
    TEST_ASSERT_TRUE(clear < deleteBonds);
    TEST_ASSERT_TRUE(deleteBonds < disconnect);
    TEST_ASSERT_TRUE(forgetBody.find("_bondPolicy.restore(acceptedIdentity)") !=
                     std::string::npos);

    const size_t commandStart = source.find("case EchoBleProtocol::FRAME_FORGET_BOND:");
    const size_t commandEnd = source.find("default:", commandStart);
    TEST_ASSERT_TRUE(commandStart != std::string::npos);
    TEST_ASSERT_TRUE(commandEnd != std::string::npos);
    const std::string commandBody = source.substr(commandStart, commandEnd - commandStart);
    TEST_ASSERT_TRUE(commandBody.find("_forgetBondPending = true") != std::string::npos);
    TEST_ASSERT_TRUE(commandBody.find("restartActive") == std::string::npos);
}

void test_transport_does_not_force_max_tx_power() {
    const std::string source = readSource("src/ble_transport.h");
    // +20dBm can brown out the XIAO's regulator during notification bursts,
    // corrupting radio timing into supervision timeouts.
    TEST_ASSERT_TRUE(source.find("setPower(") == std::string::npos);
}

void test_vad_trigger_frame_is_not_encoded_after_prebuffer_replay() {
    const std::string source = readMainSource();
    TEST_ASSERT_TRUE(source.find("preBufferCount - 1") != std::string::npos);
}

void test_muted_gate_discards_capture_before_reading_audio() {
    const std::string source = readMainSource();
    const size_t muteBlockStart = source.find("if (muteState.isMuted())");
    const size_t audioRead = source.find("audio.readSamples", muteBlockStart);

    TEST_ASSERT_TRUE(muteBlockStart != std::string::npos);
    TEST_ASSERT_TRUE(audioRead != std::string::npos);
    const std::string muteBlock = source.substr(muteBlockStart, audioRead - muteBlockStart);
    TEST_ASSERT_TRUE(muteBlock.find("discardInProgressCapture()") != std::string::npos);
    TEST_ASSERT_TRUE(muteBlock.find("finalizeSegment()") == std::string::npos);

    const size_t helperStart = source.find("void discardInProgressCapture() {");
    const size_t helperEnd = source.find("void encodeFrame", helperStart);
    TEST_ASSERT_TRUE(helperStart != std::string::npos);
    TEST_ASSERT_TRUE(helperEnd != std::string::npos);
    const std::string helper = source.substr(helperStart, helperEnd - helperStart);
    TEST_ASSERT_TRUE(helper.find("segmentPos = 0") != std::string::npos);
    TEST_ASSERT_TRUE(helper.find("encoder.reset()") != std::string::npos);
    TEST_ASSERT_TRUE(helper.find("vad.reset()") != std::string::npos);
    TEST_ASSERT_TRUE(helper.find("preBufferCount = 0") != std::string::npos);
    TEST_ASSERT_TRUE(helper.find("preBufferWriteIdx = 0") != std::string::npos);
    TEST_ASSERT_TRUE(helper.find("state = STATE_IDLE") != std::string::npos);
    TEST_ASSERT_TRUE(helper.find("indicators.setRecording(false)") != std::string::npos);
    TEST_ASSERT_TRUE(source.find("_testSegmentInjected") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("framesToGenerate") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("Stored TEST segment") == std::string::npos);
}

void test_indicators_do_not_read_or_toggle_the_mute_button() {
    const std::string source = readSource("src/indicators.h");

    TEST_ASSERT_TRUE(source.find("MUTE_BUTTON_PIN") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("ButtonDebouncer") == std::string::npos);
    TEST_ASSERT_TRUE(source.find("void setMuted(bool muted)") != std::string::npos);
    TEST_ASSERT_TRUE(source.find("_muted = muted") != std::string::npos);
}

void test_transport_gates_each_notification_at_the_deadline() {
    const std::string source = readSource("src/ble_transport.h");

    TEST_ASSERT_TRUE(source.find("const uint32_t deadlineUs =") != std::string::npos);
    TEST_ASSERT_TRUE(source.find("notifyAudio(const uint8_t* data, size_t length, uint32_t deadlineUs)") !=
                     std::string::npos);
    TEST_ASSERT_TRUE(source.find("notifyBufferStatus(const PSRAMBuffer& buffer, uint32_t deadlineUs)") !=
                     std::string::npos);
    TEST_ASSERT_EQUAL_UINT32(1, countOccurrences(source, "_audioCharacteristic->notify("));
    TEST_ASSERT_EQUAL_UINT32(2, countOccurrences(source, "_controlCharacteristic->notify("));
    TEST_ASSERT_TRUE(source.find(
        "if (!beforeBurstDeadline(deadlineUs)) return false;\n"
        "        const bool ok = _audioCharacteristic->notify") != std::string::npos);
    TEST_ASSERT_TRUE(source.find(
        "if (!beforeBurstDeadline(deadlineUs)) return false;\n"
        "        const bool notified = _controlCharacteristic->notify") != std::string::npos);
}

void test_indicator_uses_named_active_low_led_values() {
    const std::string source = readSource("src/indicators.h");
    TEST_ASSERT_TRUE(source.find("LED_ON = LOW") != std::string::npos);
    TEST_ASSERT_TRUE(source.find("LED_OFF = HIGH") != std::string::npos);
    TEST_ASSERT_TRUE(source.find("active ? LED_ON : LED_OFF") != std::string::npos);
}

void test_drop_oldest_counts_drops_but_normal_dequeue_does_not() {
    const std::string source = readSource("src/psram_buffer.h");
    const size_t dequeueStart = source.find("void PSRAMBuffer::dequeue() {");
    const size_t dropStart = source.find("uint32_t PSRAMBuffer::dropOldest() {");
    const size_t countStart = source.find("uint32_t PSRAMBuffer::droppedSegmentCount() const {");

    TEST_ASSERT_TRUE(dequeueStart != std::string::npos);
    TEST_ASSERT_TRUE(dropStart != std::string::npos);
    TEST_ASSERT_TRUE(countStart != std::string::npos);
    const std::string dequeueBody = source.substr(dequeueStart, dropStart - dequeueStart);
    const std::string dropBody = source.substr(dropStart, countStart - dropStart);
    TEST_ASSERT_TRUE(dequeueBody.find("_layout.pop(") != std::string::npos);
    TEST_ASSERT_TRUE(dequeueBody.find("_droppedSegmentCount") == std::string::npos);
    TEST_ASSERT_TRUE(dropBody.find("_layout.pop(") != std::string::npos);
    TEST_ASSERT_TRUE(dropBody.find("++_droppedSegmentCount") != std::string::npos);
}

void test_main_cancels_active_transfer_before_drop_without_dequeue() {
    const std::string source = readMainSource();
    const size_t finalizeStart = source.find("void finalizeSegment() {");
    TEST_ASSERT_TRUE(finalizeStart != std::string::npos);
    const std::string finalizeBody = source.substr(finalizeStart);
    const size_t cancel = finalizeBody.find("cancelActiveForOverflow(oldest.segmentId)");
    const size_t drop = finalizeBody.find("buffer.dropOldest()");

    TEST_ASSERT_TRUE(cancel != std::string::npos);
    TEST_ASSERT_TRUE(drop != std::string::npos);
    TEST_ASSERT_TRUE(cancel < drop);
    TEST_ASSERT_TRUE(finalizeBody.find("buffer.dequeue()") == std::string::npos);
    TEST_ASSERT_TRUE(finalizeBody.find("bleTransport.reportBufferOverflow()") != std::string::npos);
}

void test_overflow_status_serializes_counter_and_retains_flag_until_notify_succeeds() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t statusStart = source.find(
        "bool notifyBufferStatus(const PSRAMBuffer& buffer, uint32_t deadlineUs)");
    const size_t statusEnd = source.find("bool sendSegmentStart", statusStart);
    TEST_ASSERT_TRUE(statusStart != std::string::npos);
    TEST_ASSERT_TRUE(statusEnd != std::string::npos);
    const std::string statusBody = source.substr(statusStart, statusEnd - statusStart);

    TEST_ASSERT_TRUE(statusBody.find("_overflowSinceLastStatus") != std::string::npos);
    TEST_ASSERT_TRUE(statusBody.find("buffer.droppedSegmentCount()") != std::string::npos);
    const size_t notify = statusBody.find("_controlCharacteristic->notify(");
    const size_t clear = statusBody.find("_overflowSinceLastStatus = false");
    TEST_ASSERT_TRUE(notify != std::string::npos);
    TEST_ASSERT_TRUE(clear != std::string::npos);
    TEST_ASSERT_TRUE(notify < clear);
    TEST_ASSERT_TRUE(statusBody.find("if (notified)") < clear);

    const size_t reportStart = source.find("void reportBufferOverflow() {");
    const size_t privateStart = source.find("private:", reportStart);
    TEST_ASSERT_TRUE(reportStart != std::string::npos);
    TEST_ASSERT_TRUE(privateStart != std::string::npos);
    const std::string reportBody = source.substr(reportStart, privateStart - reportStart);
    TEST_ASSERT_TRUE(reportBody.find("_overflowSinceLastStatus = true") != std::string::npos);
    TEST_ASSERT_TRUE(reportBody.find("_pendingStatus.request()") != std::string::npos);
}

void test_only_accept_upload_dequeues_a_buffered_segment() {
    const std::string source = readSource("src/ble_transport.h");
    TEST_ASSERT_EQUAL_UINT32(1, countOccurrences(source, "buffer.dequeue();"));
    const size_t acceptStart = source.find("void acceptUpload(");
    const size_t membersStart = source.find("NimBLEServer* _server", acceptStart);
    TEST_ASSERT_TRUE(acceptStart != std::string::npos);
    TEST_ASSERT_TRUE(membersStart != std::string::npos);
    const std::string acceptBody = source.substr(acceptStart, membersStart - acceptStart);
    TEST_ASSERT_TRUE(acceptBody.find("buffer.dequeue();") != std::string::npos);
}

void test_overflow_cancellation_does_not_dequeue() {
    const std::string source = readSource("src/ble_transport.h");
    const size_t cancelStart = source.find("bool cancelActiveForOverflow(uint32_t segmentId) {");
    const size_t reportStart = source.find("void reportBufferOverflow()", cancelStart);
    TEST_ASSERT_TRUE(cancelStart != std::string::npos);
    TEST_ASSERT_TRUE(reportStart != std::string::npos);
    const std::string cancelBody = source.substr(cancelStart, reportStart - cancelStart);
    TEST_ASSERT_TRUE(cancelBody.find(
        "if (!_active || _segment.segmentId != segmentId) return false") !=
        std::string::npos);
    TEST_ASSERT_TRUE(cancelBody.find("_state.cancelSegment()") != std::string::npos);
    TEST_ASSERT_TRUE(cancelBody.find("_active = false") != std::string::npos);
    TEST_ASSERT_TRUE(cancelBody.find("_segmentData = nullptr") != std::string::npos);
    TEST_ASSERT_TRUE(cancelBody.find("_preambleStep = 0") != std::string::npos);
    TEST_ASSERT_TRUE(cancelBody.find("return true") != std::string::npos);
    TEST_ASSERT_TRUE(cancelBody.find("dequeue") == std::string::npos);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_main_uses_ble_only_transport);
    RUN_TEST(test_crc_is_accumulated_during_encoding_and_not_scanned_by_transport);
    RUN_TEST(test_firmware_uses_approved_latency_constants);
    RUN_TEST(test_transport_waits_for_ready_and_configures_ios_connection);
    RUN_TEST(test_nimble_callbacks_avoid_serial_io_on_the_host_task);
    RUN_TEST(test_security_is_configured_before_server_creation);
    RUN_TEST(test_gatt_characteristics_require_encryption);
    RUN_TEST(test_connect_starts_security_and_waits_for_authentication);
    RUN_TEST(test_mtu_exchange_can_complete_before_authentication);
    RUN_TEST(test_authentication_requires_encrypted_bonded_accepted_identity);
    RUN_TEST(test_existing_bonds_restore_one_peer_and_remove_extras);
    RUN_TEST(test_forget_bond_ack_precedes_store_deletion_and_disconnect);
    RUN_TEST(test_transport_does_not_force_max_tx_power);
    RUN_TEST(test_vad_trigger_frame_is_not_encoded_after_prebuffer_replay);
    RUN_TEST(test_muted_gate_discards_capture_before_reading_audio);
    RUN_TEST(test_indicators_do_not_read_or_toggle_the_mute_button);
    RUN_TEST(test_transport_gates_each_notification_at_the_deadline);
    RUN_TEST(test_indicator_uses_named_active_low_led_values);
    RUN_TEST(test_drop_oldest_counts_drops_but_normal_dequeue_does_not);
    RUN_TEST(test_main_cancels_active_transfer_before_drop_without_dequeue);
    RUN_TEST(test_overflow_status_serializes_counter_and_retains_flag_until_notify_succeeds);
    RUN_TEST(test_only_accept_upload_dequeues_a_buffered_segment);
    RUN_TEST(test_overflow_cancellation_does_not_dequeue);
    return UNITY_END();
}