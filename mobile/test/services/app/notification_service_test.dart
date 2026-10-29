import 'package:echo_app/services/app/notification_service.dart';
import 'package:echo_app/models/upcoming_notification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('upcoming notifications replace the previous ones, past ones skipped',
      () async {
    final port = _FakeNotificationPort();
    final service = NotificationService(port);
    final now = DateTime.utc(2026, 10, 15, 8);
    UpcomingNotification item(String key, DateTime at, String target) =>
        UpcomingNotification(
            key: key,
            kind: 'briefing',
            fireAt: at,
            title: 'T $key',
            body: 'B',
            target: target);

    await service.replaceUpcoming([
      item('past', now.subtract(const Duration(minutes: 5)), 'today'),
      item('a', now.add(const Duration(hours: 2)), 'person:p1'),
      item('b', now.add(const Duration(hours: 5)), 'tasks'),
    ], now);

    expect(port.cancelled, List.generate(10, (i) => 300 + i));
    expect(port.scheduled.map((c) => (c.id, c.title, c.delay, c.payload)), [
      (300, 'T a', const Duration(hours: 2), 'person:p1'),
      (301, 'T b', const Duration(hours: 5), 'tasks'),
    ]);
  });

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
    // Why it happened and what to do, not the wearable's internals
    expect(port.shown.first.title, "Some speech wasn't saved");
    expect(port.shown.first.body, contains('memory was full'));
    expect(port.shown.first.body, contains('near Echo'));
    await service.showLoss(1);
    expect(port.shown.last.body, contains('1 recording was'));
  });

  test('who is in front of you shows at once and opens the person', () async {
    final port = _FakeNotificationPort();
    final service = NotificationService(port);

    await service.showPersonBrief(
        personId: 'p1', title: 'Talking with Marco', body: 'You promised: the quote');
    await service.showPersonBrief(personId: 'p2', title: 'Talking with Ada', body: 'B');

    // Two people, two notifications: the second does not replace the first
    expect(port.shown.map((c) => (c.id, c.title, c.body, c.payload)), [
      (400, 'Talking with Marco', 'You promised: the quote', 'person:p1'),
      (401, 'Talking with Ada', 'B', 'person:p2'),
    ]);
  });

  test('a photo taken with the app in the background says so and opens Ask', () async {
    final port = _FakeNotificationPort();
    final service = NotificationService(port);

    await service.showPhotoTaken();

    expect(port.shown.map((c) => (c.id, c.title, c.payload)), [
      (104, '📷 Photo taken', 'voice:'),
    ]);
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
    this.payload,
  });

  final int id;
  final String title;
  final String body;
  final Duration? delay;
  final String? payload;
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
    String? payload,
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
      payload: payload,
    ));
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    shown.add(_NotificationCall(id: id, title: title, body: body, payload: payload));
  }
}
