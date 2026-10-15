import 'dart:async';

import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/services/device/live_activity_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('echo/live_activity');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('the state follows the wearable', () {
    expect(
      LiveActivityState.from(
          const DeviceStatus(connectionState: DeviceConnectionState.unpaired)),
      isNull,
    );
    final listening = LiveActivityState.from(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      batteryPercent: 64,
      bufferBytes: 8 * 1024 * 60 * 3,
    ))!;
    expect(listening.toArguments(),
        {'status': 'listening', 'battery': 64, 'pendingMinutes': 3});
    expect(
      LiveActivityState.from(
        const DeviceStatus(connectionState: DeviceConnectionState.reconnecting),
      )!
          .status,
      'offline',
    );
  });

  test('updates only on a change, ends when unpaired or switched off',
      () async {
    final statuses = StreamController<DeviceStatus>();
    var enabled = true;
    final service = LiveActivityService(
      initial:
          const DeviceStatus(connectionState: DeviceConnectionState.listening),
      statuses: statuses.stream,
      enabled: () => enabled,
    )..start();
    await pumpEventQueue();
    expect(calls.map((c) => c.method), ['update']);

    statuses.add(
        const DeviceStatus(connectionState: DeviceConnectionState.listening));
    await pumpEventQueue();
    expect(calls, hasLength(1)); // nothing changed

    statuses
        .add(const DeviceStatus(connectionState: DeviceConnectionState.muted));
    await pumpEventQueue();
    expect((calls.last.arguments as Map)['status'], 'muted');

    enabled = false;
    await service.refresh();
    expect(calls.last.method, 'end');

    enabled = true;
    statuses.add(
        const DeviceStatus(connectionState: DeviceConnectionState.unpaired));
    await pumpEventQueue();
    expect(calls.last.method, 'end');
    expect(
        calls.where((c) => c.method == 'end'), hasLength(1)); // already ended

    await service.dispose();
    await statuses.close();
  });

  test('without the native side nothing fails', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final service = LiveActivityService(
      initial:
          const DeviceStatus(connectionState: DeviceConnectionState.listening),
      statuses: const Stream.empty(),
      enabled: () => true,
    );
    await service.refresh();
  });
}
