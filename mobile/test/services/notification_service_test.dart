import 'package:echo_app/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initialize does not request permission', () async {
    final port = _FakeNotificationPort();
    final service = NotificationService(port);

    await service.initialize();

    expect(port.initializeCalls, 1);
    expect(port.permissionCalls, 0);
  });

  test('permission is delegated only when explicitly requested', () async {
    final port = _FakeNotificationPort(permissionGranted: true);
    final service = NotificationService(port);

    expect(await service.requestPermission(), isTrue);
    expect(port.permissionCalls, 1);
  });

  test('disconnect warning uses fixed ID and two-minute delay once', () async {
    final port = _FakeNotificationPort();
    final service = NotificationService(port);

    await service.scheduleDisconnected();
    await service.scheduleDisconnected();

    expect(port.scheduled, hasLength(1));
    expect(port.scheduled.single.id, NotificationService.disconnectId);
    expect(port.scheduled.single.delay, const Duration(minutes: 2));
  });

  test('failed disconnect scheduling can be retried', () async {
    final port = _FakeNotificationPort()..failNextSchedule = true;
    final service = NotificationService(port);

    await expectLater(service.scheduleDisconnected(), throwsStateError);
    await service.scheduleDisconnected();

    expect(port.scheduled, hasLength(1));
  });

  test('cancel disconnect clears the pending warning and permits reschedule',
      () async {
    final port = _FakeNotificationPort();
    final service = NotificationService(port);
    await service.scheduleDisconnected();

    await service.cancelDisconnected();
    await service.scheduleDisconnected();

    expect(port.cancelled, [NotificationService.disconnectId]);
    expect(port.scheduled, hasLength(2));
  });

  test('loss and upload failure use fixed IDs and useful content', () async {
    final port = _FakeNotificationPort();
    final service = NotificationService(port);

    await service.showLoss(4);
    await service.showUploadFailure();

    expect(port.shown.map((notification) => notification.id), [
      NotificationService.lossId,
      NotificationService.uploadFailureId,
    ]);
    expect(port.shown.first.body, contains('4'));
  });

  test('normal transcript completion produces no notification', () async {
    final port = _FakeNotificationPort();
    final service = NotificationService(port);

    await service.segmentCompleted();

    expect(port.shown, isEmpty);
    expect(port.scheduled, isEmpty);
  });
}

final class _NotificationCall {
  const _NotificationCall({
    required this.id,
    required this.title,
    required this.body,
    this.delay,
  });

  final int id;
  final String title;
  final String body;
  final Duration? delay;
}

final class _FakeNotificationPort implements NotificationPort {
  _FakeNotificationPort({this.permissionGranted = false});

  final bool permissionGranted;
  final List<_NotificationCall> scheduled = [];
  final List<_NotificationCall> shown = [];
  final List<int> cancelled = [];
  int initializeCalls = 0;
  int permissionCalls = 0;
  bool failNextSchedule = false;

  @override
  Future<void> initialize() async => initializeCalls++;

  @override
  Future<bool> requestPermission() async {
    permissionCalls++;
    return permissionGranted;
  }

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required Duration delay,
  }) async {
    if (failNextSchedule) {
      failNextSchedule = false;
      throw StateError('schedule failed');
    }
    scheduled.add(_NotificationCall(
      id: id,
      title: title,
      body: body,
      delay: delay,
    ));
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    shown.add(_NotificationCall(id: id, title: title, body: body));
  }
}