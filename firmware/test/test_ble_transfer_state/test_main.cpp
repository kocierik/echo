#include <unity.h>

#include "ble_transport_events.h"
#include "ble_transfer_state.h"

void test_ready_gates_transfer_and_first_window_is_eight_chunks() {
    BleTransferState state;
    state.beginSegment(42, 20, 1000);
    TEST_ASSERT_EQUAL(BleTransferState::WAITING_READY, state.phase());
    TEST_ASSERT_FALSE(state.canSend(1000));
    state.onReady();
    TEST_ASSERT_TRUE(state.canSend(1000));
    TEST_ASSERT_EQUAL_UINT16(0, state.nextSequence());
    for (uint16_t sequence = 0; sequence < 8; ++sequence) {
        state.onChunkSent(sequence, 1000 + sequence);
    }
    TEST_ASSERT_EQUAL(BleTransferState::WAITING_ACK, state.phase());
    TEST_ASSERT_FALSE(state.canSend(1010));
}

void test_valid_ack_advances_and_wrong_or_stale_ack_is_rejected() {
    BleTransferState state;
    state.beginSegment(42, 12, 0);
    state.onReady();
    for (uint16_t sequence = 0; sequence < 8; ++sequence) state.onChunkSent(sequence, sequence);
    TEST_ASSERT_FALSE(state.onAckWindow(7, 7, 10));
    TEST_ASSERT_FALSE(state.onAckWindow(42, 6, 10));
    TEST_ASSERT_TRUE(state.onAckWindow(42, 7, 10));
    TEST_ASSERT_EQUAL_UINT16(8, state.nextSequence());
    TEST_ASSERT_EQUAL(BleTransferState::SENDING_WINDOW, state.phase());
}

void test_timeout_and_restart_request_restart_from_start() {
    BleTransferState state;
    state.beginSegment(9, 10, 0);
    state.onReady();
    for (uint16_t sequence = 0; sequence < 8; ++sequence) state.onChunkSent(sequence, sequence);
    TEST_ASSERT_TRUE(state.update(BleTransferState::ACK_TIMEOUT_MS + 10));
    TEST_ASSERT_EQUAL(BleTransferState::RESTARTING, state.phase());
    state.restartComplete(2000);
    TEST_ASSERT_EQUAL_UINT16(0, state.nextSequence());
    TEST_ASSERT_EQUAL(BleTransferState::SENDING_WINDOW, state.phase());
    TEST_ASSERT_TRUE(state.onRestartSegment(9));
    TEST_ASSERT_EQUAL(BleTransferState::RESTARTING, state.phase());
}

void test_upload_ok_only_after_every_chunk_acknowledged() {
    BleTransferState state;
    state.beginSegment(77, 2, 0);
    state.onReady();
    state.onChunkSent(0, 1);
    state.onChunkSent(1, 2);
    TEST_ASSERT_FALSE(state.canAcceptUploadOk(77));
    TEST_ASSERT_TRUE(state.onAckWindow(77, 1, 3));
    TEST_ASSERT_EQUAL(BleTransferState::WAITING_UPLOAD, state.phase());
    TEST_ASSERT_FALSE(state.canAcceptUploadOk(76));
    TEST_ASSERT_TRUE(state.canAcceptUploadOk(77));
}

void test_ready_is_cleared_by_disconnect_and_required_for_new_segment() {
    BleTransferState state;
    state.onReady();
    TEST_ASSERT_TRUE(state.isReady());
    state.onDisconnected();
    TEST_ASSERT_FALSE(state.isReady());

    state.beginSegment(88, 1, 0);
    TEST_ASSERT_EQUAL(BleTransferState::WAITING_READY, state.phase());
    TEST_ASSERT_FALSE(state.canSend(0));
}

void test_transport_event_queue_copies_control_data_in_fifo_order() {
    BleTransportEventQueue queue;
    const uint8_t ready[] = {EchoBleProtocol::FRAME_READY};
    const uint8_t uploadOk[] = {EchoBleProtocol::FRAME_UPLOAD_OK, 42, 0, 0, 0};

    TEST_ASSERT_TRUE(queue.push(BleTransportEvent::control(ready, sizeof(ready))));
    TEST_ASSERT_TRUE(queue.push(BleTransportEvent::control(uploadOk, sizeof(uploadOk))));

    BleTransportEvent event = {};
    TEST_ASSERT_TRUE(queue.pop(event));
    TEST_ASSERT_EQUAL(BleTransportEventType::CONTROL, event.type);
    TEST_ASSERT_EQUAL_UINT16(sizeof(ready), event.controlLength);
    TEST_ASSERT_EQUAL_UINT8(EchoBleProtocol::FRAME_READY, event.controlData[0]);

    TEST_ASSERT_TRUE(queue.pop(event));
    TEST_ASSERT_EQUAL_UINT16(sizeof(uploadOk), event.controlLength);
    TEST_ASSERT_EQUAL_UINT8_ARRAY(uploadOk, event.controlData, sizeof(uploadOk));
    TEST_ASSERT_FALSE(queue.pop(event));
}

void test_transport_event_queue_rejects_overflow_without_overwriting() {
    BleTransportEventQueue queue;
    for (size_t index = 0; index < BleTransportEventQueue::CAPACITY; ++index) {
        TEST_ASSERT_TRUE(queue.push(BleTransportEvent::mtuChanged(
            static_cast<uint16_t>(23 + index))));
    }
    TEST_ASSERT_FALSE(queue.push(BleTransportEvent::connected()));

    BleTransportEvent event = {};
    for (size_t index = 0; index < BleTransportEventQueue::CAPACITY; ++index) {
        TEST_ASSERT_TRUE(queue.pop(event));
        TEST_ASSERT_EQUAL(BleTransportEventType::MTU_CHANGED, event.type);
        TEST_ASSERT_EQUAL_UINT16(23 + index, event.mtu);
    }
    TEST_ASSERT_FALSE(queue.pop(event));
}

void test_control_event_preserves_invalid_length_without_copying_past_capacity() {
    uint8_t oversized[EchoBleProtocol::MAX_CONTROL_FRAME_SIZE + 1] = {};
    oversized[0] = 0x7F;
    const BleTransportEvent event = BleTransportEvent::control(oversized, sizeof(oversized));

    TEST_ASSERT_EQUAL_UINT16(sizeof(oversized), event.controlLength);
    TEST_ASSERT_EQUAL_UINT8(0x7F, event.controlData[0]);
}

void test_pending_status_waits_for_ready_and_successful_notification() {
    BlePendingStatus status;
    status.request(1);

    TEST_ASSERT_FALSE(status.shouldNotify(false, false));
    TEST_ASSERT_FALSE(status.shouldNotify(true, false));
    TEST_ASSERT_TRUE(status.isPending());
    TEST_ASSERT_EQUAL_UINT8(1, status.errorCode());

    TEST_ASSERT_TRUE(status.shouldNotify(true, true));
    status.onNotifyResult(false);
    TEST_ASSERT_TRUE(status.isPending());
    TEST_ASSERT_EQUAL_UINT8(1, status.errorCode());

    status.onNotifyResult(true);
    TEST_ASSERT_FALSE(status.isPending());
    TEST_ASSERT_EQUAL_UINT8(0, status.errorCode());
}

void test_normal_status_request_does_not_clear_pending_error() {
    BlePendingStatus status;
    status.request(1);
    status.request(0);

    TEST_ASSERT_TRUE(status.isPending());
    TEST_ASSERT_EQUAL_UINT8(1, status.errorCode());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_ready_gates_transfer_and_first_window_is_eight_chunks);
    RUN_TEST(test_valid_ack_advances_and_wrong_or_stale_ack_is_rejected);
    RUN_TEST(test_timeout_and_restart_request_restart_from_start);
    RUN_TEST(test_upload_ok_only_after_every_chunk_acknowledged);
    RUN_TEST(test_ready_is_cleared_by_disconnect_and_required_for_new_segment);
    RUN_TEST(test_transport_event_queue_copies_control_data_in_fifo_order);
    RUN_TEST(test_transport_event_queue_rejects_overflow_without_overwriting);
    RUN_TEST(test_control_event_preserves_invalid_length_without_copying_past_capacity);
    RUN_TEST(test_pending_status_waits_for_ready_and_successful_notification);
    RUN_TEST(test_normal_status_request_does_not_clear_pending_error);
    return UNITY_END();
}