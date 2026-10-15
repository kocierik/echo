import 'dart:async';

import 'package:echo_app/services/device/ble_packet_assembler.dart';
import 'package:echo_app/services/device/ble_relay_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BleRelayController', () {
    test('serializes control writes', () async {
      final writes = <List<int>>[];
      final completions = <Completer<void>>[];
      final controller = BleRelayController(
        upload: (_) async => true,
        writeControl: (value) {
          writes.add(value);
          final completion = Completer<void>();
          completions.add(completion);
          return completion.future;
        },
      )..setConnected(true);

      final first = controller.handleEvents([
        const BleAckRequired(segmentId: 7, highestSequence: 31),
      ]);
      final second = controller.handleEvents([
        const BleAckRequired(segmentId: 7, highestSequence: 63),
      ]);
      await _flush();

      expect(writes, hasLength(1));
      expect(_readU16(writes.first, 5), 31);
      completions.first.complete();
      await first;
      await _flush();
      expect(writes, hasLength(2));
      expect(_readU16(writes.last, 5), 63);
      completions.last.complete();
      await second;
    });

    test('finishes final ACK before upload and sends UPLOAD_OK only for true', () async {
      final ackComplete = Completer<void>();
      final writes = <List<int>>[];
      final uploadedSegments = <int>[];
      var uploadCalls = 0;
      final controller = BleRelayController(
        upload: (_) async {
          uploadCalls++;
          return true;
        },
        writeControl: (value) {
          writes.add(value);
          if (value.first == 0x11) return ackComplete.future;
          return Future.value();
        },
        onUploaded: uploadedSegments.add,
      )..setConnected(true);

      final handling = controller.handleEvents([
        const BleAckRequired(segmentId: 7, highestSequence: 4),
        BleSegmentCompleted(_segment(7)),
      ]);
      await _flush();
      expect(uploadCalls, 0);
      expect(writes.map((value) => value.first), [0x11]);

      ackComplete.complete();
      await handling;
      await controller.attemptComplete;
      expect(uploadCalls, 1);
      expect(writes.map((value) => value.first), [0x11, 0x13]);
      expect(uploadedSegments, [7]);
    });

    test('false upload result schedules retry and never sends UPLOAD_OK', () async {
      final scheduler = _FakeScheduler();
      final writes = <List<int>>[];
      final statuses = <String>[];
      final controller = BleRelayController(
        upload: (_) async => false,
        writeControl: (value) async => writes.add(value),
        scheduleRetry: scheduler.schedule,
        onStatus: (message, {required isError}) {
          if (isError) statuses.add(message);
        },
      )..setConnected(true);

      await controller.handleEvents([BleSegmentCompleted(_segment(1))]);
      await controller.attemptComplete;

      expect(writes, isEmpty);
      expect(scheduler.delays, [const Duration(seconds: 2)]);
      expect(statuses, ['Segment 1 upload rejected; retrying']);
    });

    test('retries UPLOAD_OK without uploading the segment again', () async {
      final scheduler = _FakeScheduler();
      final uploadedSegments = <int>[];
      var uploadCalls = 0;
      var uploadOkWrites = 0;
      final controller = BleRelayController(
        upload: (_) async {
          uploadCalls++;
          return true;
        },
        writeControl: (value) async {
          if (value.first != 0x13) return;
          uploadOkWrites++;
          if (uploadOkWrites == 1) throw StateError('write failed');
        },
        scheduleRetry: scheduler.schedule,
        onUploaded: uploadedSegments.add,
      )..setConnected(true);

      await controller.handleEvents([BleSegmentCompleted(_segment(10))]);
      await controller.attemptComplete;
      expect(uploadCalls, 1);
      expect(uploadOkWrites, 1);
      expect(scheduler.delays, [const Duration(seconds: 2)]);
      expect(uploadedSegments, isEmpty);

      scheduler.fire(0);
      await _flush();
      await controller.attemptComplete;
      expect(uploadCalls, 1);
      expect(uploadOkWrites, 2);
      expect(scheduler.delays, [const Duration(seconds: 2)]);
      expect(uploadedSegments, [10]);
    });

    test('disconnect cancels permanently failing UPLOAD_OK retries', () async {
      final scheduler = _FakeScheduler();
      var uploadCalls = 0;
      var uploadOkWrites = 0;
      final controller = BleRelayController(
        upload: (_) async {
          uploadCalls++;
          return true;
        },
        writeControl: (value) async {
          if (value.first == 0x13) {
            uploadOkWrites++;
            throw StateError('write failed');
          }
        },
        scheduleRetry: scheduler.schedule,
      )..setConnected(true);

      await controller.handleEvents([BleSegmentCompleted(_segment(11))]);
      await controller.attemptComplete;
      scheduler.fire(0);
      await _flush();
      await controller.attemptComplete;
      expect(scheduler.delays, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);

      controller.setConnected(false);
      expect(scheduler.handles.last.isCancelled, isTrue);
      scheduler.fire(1);
      await _flush();
      expect(uploadCalls, 1);
      expect(uploadOkWrites, 2);
    });

    test('queued ACK from an old generation cannot cross reconnect', () async {
      final writes = <List<int>>[];
      final completions = <Completer<void>>[];
      final controller = BleRelayController(
        upload: (_) async => true,
        writeControl: (value) {
          writes.add(value);
          final completion = Completer<void>();
          completions.add(completion);
          return completion.future;
        },
      )..setConnected(true);

      final stale = controller.handleEvents(const [
        BleAckRequired(segmentId: 12, highestSequence: 31),
        BleAckRequired(segmentId: 12, highestSequence: 63),
      ]);
      await _flush();

      controller.setConnected(false);
      controller.setConnected(true);
      final fresh = controller.handleEvents(const [
        BleAckRequired(segmentId: 13, highestSequence: 7),
      ]);
      await _flush();
      expect(writes.map((value) => _readU16(value, 5)), [31, 7]);

      completions.first.complete();
      await stale;
      expect(writes.map((value) => _readU16(value, 5)), [31, 7]);
      completions.last.complete();
      await fresh;
    });

    test('queued restart from an old generation cannot cross reconnect', () async {
      final writes = <List<int>>[];
      final completions = <Completer<void>>[];
      final controller = BleRelayController(
        upload: (_) async => true,
        writeControl: (value) {
          writes.add(value);
          final completion = Completer<void>();
          completions.add(completion);
          return completion.future;
        },
      )..setConnected(true);

      final stale = controller.handleEvents(const [
        BleAckRequired(segmentId: 14, highestSequence: 31),
        BleRestartRequired(segmentId: 14, reason: 'invalid chunk'),
      ]);
      await _flush();

      controller.setConnected(false);
      controller.setConnected(true);
      final fresh = controller.sendControl(const [0x10]);
      await _flush();
      expect(writes.map((value) => value.first), [0x11, 0x10]);

      completions.first.complete();
      await stale;
      expect(writes.map((value) => value.first), [0x11, 0x10]);
      completions.last.complete();
      await fresh;
    });

    test('queued UPLOAD_OK from an old generation cannot cross reconnect', () async {
      final writes = <List<int>>[];
      final completions = <Completer<void>>[];
      var uploadCalls = 0;
      final controller = BleRelayController(
        upload: (_) async {
          uploadCalls++;
          return true;
        },
        writeControl: (value) {
          writes.add(value);
          final completion = Completer<void>();
          completions.add(completion);
          return completion.future;
        },
      )..setConnected(true);

      final active = controller.sendControl(const [0x14]);
      await controller.handleEvents([BleSegmentCompleted(_segment(15))]);
      await _flush();
      expect(uploadCalls, 1);

      controller.setConnected(false);
      controller.setConnected(true);
      final fresh = controller.sendControl(const [0x10]);
      await _flush();
      expect(writes.map((value) => value.first), [0x14, 0x10]);

      completions.first.complete();
      await active;
      await _flush();
      expect(writes.map((value) => value.first), [0x14, 0x10]);
      expect(uploadCalls, 1);
      completions.last.complete();
      await fresh;
    });

    test('writes RESTART_SEGMENT with the assembler segment ID', () async {
      final writes = <List<int>>[];
      final controller = BleRelayController(
        upload: (_) async => true,
        writeControl: (value) async => writes.add(value),
      )..setConnected(true);

      await controller.handleEvents(const [
        BleRestartRequired(segmentId: 0x12345678, reason: 'CRC mismatch'),
      ]);

      expect(writes.single.first, 0x12);
      expect(
        writes.single.sublist(1),
        orderedEquals([0x78, 0x56, 0x34, 0x12]),
      );
    });

    test('upload exception schedules retry', () async {
      final scheduler = _FakeScheduler();
      final controller = BleRelayController(
        upload: (_) => Future<bool>.error(StateError('network unavailable')),
        writeControl: (_) async {},
        scheduleRetry: scheduler.schedule,
      )..setConnected(true);

      await controller.handleEvents([BleSegmentCompleted(_segment(2))]);
      await controller.attemptComplete;

      expect(scheduler.delays, [const Duration(seconds: 2)]);
    });

    test('upload timeout schedules retry', () async {
      final scheduler = _FakeScheduler();
      final controller = BleRelayController(
        upload: (_) => Completer<bool>().future,
        writeControl: (_) async {},
        scheduleRetry: scheduler.schedule,
        uploadTimeout: Duration.zero,
      )..setConnected(true);

      await controller.handleEvents([BleSegmentCompleted(_segment(3))]);
      await controller.attemptComplete;

      expect(scheduler.delays, [const Duration(seconds: 2)]);
    });

    test('retries after 2, 5, 10, then repeated 30 second delays', () async {
      final scheduler = _FakeScheduler();
      final controller = BleRelayController(
        upload: (_) async => false,
        writeControl: (_) async {},
        scheduleRetry: scheduler.schedule,
      )..setConnected(true);

      await controller.handleEvents([BleSegmentCompleted(_segment(4))]);
      await controller.attemptComplete;
      for (var index = 0; index < 4; index++) {
        scheduler.fire(index);
        await _flush();
        await controller.attemptComplete;
      }

      expect(scheduler.delays, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(seconds: 30),
      ]);
    });

    test('ignores duplicate completion while upload is active', () async {
      final uploadComplete = Completer<bool>();
      var uploadCalls = 0;
      final controller = BleRelayController(
        upload: (_) {
          uploadCalls++;
          return uploadComplete.future;
        },
        writeControl: (_) async {},
      )..setConnected(true);
      final completed = BleSegmentCompleted(_segment(5));

      await controller.handleEvents([completed, completed]);
      await _flush();
      expect(uploadCalls, 1);

      uploadComplete.complete(false);
      await controller.attemptComplete;
    });

    test('disconnect cancels retry and clears retained local work', () async {
      final scheduler = _FakeScheduler();
      var uploadCalls = 0;
      final controller = BleRelayController(
        upload: (_) async {
          uploadCalls++;
          return false;
        },
        writeControl: (_) async {},
        scheduleRetry: scheduler.schedule,
      )..setConnected(true);

      await controller.handleEvents([BleSegmentCompleted(_segment(6))]);
      await controller.attemptComplete;
      controller.setConnected(false);
      expect(scheduler.handles.single.isCancelled, isTrue);

      scheduler.fire(0);
      await _flush();
      expect(uploadCalls, 1);

      controller.setConnected(true);
      await controller.handleEvents([BleSegmentCompleted(_segment(6))]);
      await controller.attemptComplete;
      expect(uploadCalls, 2);
    });

    test('dispose cancels retry and ignores future work', () async {
      final scheduler = _FakeScheduler();
      var uploadCalls = 0;
      final controller = BleRelayController(
        upload: (_) async {
          uploadCalls++;
          return false;
        },
        writeControl: (_) async {},
        scheduleRetry: scheduler.schedule,
      )..setConnected(true);

      await controller.handleEvents([BleSegmentCompleted(_segment(8))]);
      await controller.attemptComplete;
      controller.dispose();
      expect(scheduler.handles.single.isCancelled, isTrue);

      scheduler.fire(0);
      await controller.handleEvents([BleSegmentCompleted(_segment(9))]);
      await _flush();
      expect(uploadCalls, 1);
    });
  });
}

BleCompletedSegment _segment(int id) {
  return BleCompletedSegment(
    id: id,
    adpcmBytes: [1, 2, 3],
    recordedAt: DateTime.utc(2026, 8, 2),
    durationMs: 6000,
    silenceBeforeMs: 640,
    averageEnergy: 321,
  );
}

int _readU16(List<int> data, int offset) {
  return data[offset] | (data[offset + 1] << 8);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _FakeScheduler {
  final List<Duration> delays = [];
  final List<_FakeRetryHandle> handles = [];
  final List<void Function()> _callbacks = [];

  BleRetryHandle schedule(Duration delay, void Function() callback) {
    final handle = _FakeRetryHandle();
    delays.add(delay);
    handles.add(handle);
    _callbacks.add(callback);
    return handle;
  }

  void fire(int index) {
    if (!handles[index].isCancelled) _callbacks[index]();
  }
}

class _FakeRetryHandle implements BleRetryHandle {
  bool isCancelled = false;

  @override
  void cancel() => isCancelled = true;
}