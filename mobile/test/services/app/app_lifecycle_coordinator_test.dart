import 'dart:async';

import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/services/app/app_lifecycle_coordinator.dart';
import 'package:echo_app/services/app/network_policy.dart';
import 'package:echo_app/services/app/notification_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late StreamController<DeviceStatus> states;
  late StreamController<int> uploadFailures;
  late StreamController<int> uploads;
  late _FakeNotificationPort notificationPort;
  late NotificationService notifications;
  late _FakeNetworkAccess network;
  late List<WidgetsBindingObserver> observers;
  late AppLifecycleBinding binding;
  var controllerStartCalls = 0;

  setUp(() async {
    states = StreamController<DeviceStatus>.broadcast(sync: true);
    uploadFailures = StreamController<int>.broadcast(sync: true);
    uploads = StreamController<int>.broadcast(sync: true);
    notificationPort = _FakeNotificationPort();
    notifications = NotificationService(notificationPort);
    network = _FakeNetworkAccess();
    observers = [];
    binding = await AppLifecycleCoordinator.startBinding(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.unpaired,
      ),
      statusStream: states.stream,
      uploadFailureStream: uploadFailures.stream,
      segmentUploadedStream: uploads.stream,
      notifications: notifications,
      networkAccess: network,
      startController: () async => controllerStartCalls++,
      addObserver: observers.add,
      removeObserver: observers.remove,
    );
  });

  tearDown(() async {
    await binding.dispose();
    await states.close();
    await uploadFailures.close();
    await uploads.close();
  });

  test('starts controller and maps connected and disconnected states',
      () async {
    expect(controllerStartCalls, 1);
    expect(observers, [binding]);

    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.reconnecting,
    ));
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.offline,
    ));
    expect(notificationPort.scheduledIds, [NotificationService.disconnectId]);

    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
    ));
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.muted,
    ));
    expect(notificationPort.cancelledIds, [NotificationService.disconnectId]);
  });

  test('notifies only when the dropped segment count increases', () async {
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      droppedSegments: 2,
    ));
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      droppedSegments: 2,
    ));
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      droppedSegments: 5,
    ));

    expect(notificationPort.lossCounts, [2, 5]);
  });

  test('adopts a reset dropped counter before reporting new loss', () async {
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      droppedSegments: 7,
    ));
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      droppedSegments: 0,
    ));
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      droppedSegments: 1,
    ));

    expect(notificationPort.lossCounts, [7, 1]);
  });

  test('shows the third upload failure once until a successful upload',
      () async {
    uploadFailures.add(1);
    uploadFailures.add(2);
    uploadFailures.add(3);
    uploadFailures.add(4);
    expect(notificationPort.uploadFailureCalls, 1);

    uploads.add(42);
    uploadFailures.add(1);
    uploadFailures.add(2);
    uploadFailures.add(3);
    expect(notificationPort.uploadFailureCalls, 2);
  });

  test('resume refreshes network types without fabricating success', () async {
    binding.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(network.calls, 1);
    expect(notificationPort.shownIds, isEmpty);
  });

  test('resume triggers reconnect recovery when available', () async {
    var reconnectCalls = 0;
    final resumeBinding = await AppLifecycleCoordinator.startBinding(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.offline,
      ),
      statusStream: states.stream,
      uploadFailureStream: uploadFailures.stream,
      segmentUploadedStream: uploads.stream,
      notifications: notifications,
      networkAccess: network,
      startController: () async {},
      reconnectOnResume: () async {
        reconnectCalls++;
      },
      addObserver: observers.add,
      removeObserver: observers.remove,
    );

    resumeBinding.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(reconnectCalls, 1);

    await resumeBinding.dispose();
  });

  test('segment uploads and resume trigger the wake callback', () async {
    var wakeCalls = 0;
    final wakeBinding = await AppLifecycleCoordinator.startBinding(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.offline,
      ),
      statusStream: states.stream,
      uploadFailureStream: uploadFailures.stream,
      segmentUploadedStream: uploads.stream,
      notifications: notifications,
      networkAccess: network,
      startController: () async {},
      onWake: () async {
        wakeCalls++;
        throw StateError('wake failures must be swallowed');
      },
      addObserver: observers.add,
      removeObserver: observers.remove,
    );

    uploads.add(1);
    wakeBinding.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(wakeCalls, 2);

    await wakeBinding.dispose();
  });

  test('dispose cancels subscriptions and unregisters observer', () async {
    await binding.dispose();
    states.add(const DeviceStatus(
      connectionState: DeviceConnectionState.offline,
      droppedSegments: 9,
    ));
    uploadFailures.add(3);

    expect(observers, isEmpty);
    expect(notificationPort.scheduledIds, isEmpty);
    expect(notificationPort.lossCounts, isEmpty);
    expect(notificationPort.uploadFailureCalls, 0);
  });

  test('network policy reads cellular preference and defaults to allowed',
      () async {
    SharedPreferences.setMockInitialValues({
      AppLifecycleCoordinator.allowCellularPreferenceKey: false,
    });
    var preferences = await SharedPreferences.getInstance();
    expect(
      AppLifecycleCoordinator.networkPolicyFrom(preferences).allowCellular,
      isFalse,
    );

    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    expect(
      AppLifecycleCoordinator.networkPolicyFrom(preferences).allowCellular,
      isTrue,
    );
  });
}

final class _FakeNetworkAccess implements NetworkAccess {
  int calls = 0;

  @override
  Future<Set<NetworkType>> currentTypes() async {
    calls++;
    return <NetworkType>{};
  }
}

final class _FakeNotificationPort implements NotificationPort {
  final List<int> scheduledIds = [];
  final List<int> cancelledIds = [];
  final List<int> shownIds = [];
  final List<int> lossCounts = [];
  int uploadFailureCalls = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required Duration delay,
    String? payload,
  }) async {
    scheduledIds.add(id);
  }

  @override
  Future<void> cancel(int id) async => cancelledIds.add(id);

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    shownIds.add(id);
    if (id == NotificationService.lossId) {
      lossCounts.add(int.parse(RegExp(r'\d+').firstMatch(body)!.group(0)!));
    }
    if (id == NotificationService.uploadFailureId) uploadFailureCalls++;
  }
}
