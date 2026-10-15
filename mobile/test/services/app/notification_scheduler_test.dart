import 'package:echo_app/models/upcoming_notification.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/app/notification_scheduler.dart';
import 'package:echo_app/services/app/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _FakeApi implements NotificationsApi {
  final calls = <(bool, bool, bool)>[];
  final phoneEvents = <List<Map<String, Object?>>>[];
  Object? error;

  @override
  Future<List<UpcomingNotification>> getUpcomingNotifications({
    required bool briefings,
    required bool promises,
    required bool evening,
    List<Map<String, Object?>> phoneEvents = const [],
  }) async {
    calls.add((briefings, promises, evening));
    this.phoneEvents.add(phoneEvents);
    if (error != null) throw error!;
    return [
      UpcomingNotification(
        key: 'promises:2026-10-16',
        kind: 'promises',
        fireAt: DateTime.utc(2026, 10, 16, 7),
        title: 'Promise for today',
        body: 'Mandare il preventivo',
        target: 'tasks',
      ),
    ];
  }
}

final class _RecordingPort implements NotificationPort {
  final scheduled = <String?>[];

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required Duration delay,
    String? payload,
  }) async =>
      scheduled.add(payload);

  @override
  Future<void> cancel(int id) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late _FakeApi api;
  late _RecordingPort port;
  late SharedPreferences preferences;
  late DateTime now;
  late NotificationScheduler scheduler;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    api = _FakeApi();
    port = _RecordingPort();
    now = DateTime.utc(2026, 10, 15, 9);
    scheduler = NotificationScheduler(
      api: api,
      notifications: NotificationService(port),
      preferences: NotificationPreferences(preferences),
      clock: () => now,
    );
  });

  test("the iPhone calendar's next events go along, for briefings only", () async {
    final event = {'id': 'e1', 'title': 'Call'};
    var reads = 0;
    scheduler = NotificationScheduler(
      api: api,
      notifications: NotificationService(port),
      preferences: NotificationPreferences(preferences),
      phoneEvents: () async {
        reads++;
        return [event];
      },
      clock: () => now,
    );

    await scheduler.refresh();
    await NotificationPreferences(preferences)
        .set(NotificationPreferences.briefingsKey, false);
    await scheduler.refresh(force: true);

    expect(api.phoneEvents, [
      [event],
      <Map<String, Object?>>[],
    ]);
    expect(reads, 1);
  });

  test('briefings and promises by default, the evening recap off', () async {
    await scheduler.refresh();
    expect(api.calls, [(true, true, false)]);
    expect(port.scheduled, ['tasks']);
  });

  test('at most every 30 minutes, unless forced', () async {
    await scheduler.refresh();
    now = now.add(const Duration(minutes: 10));
    await scheduler.refresh();
    expect(api.calls, hasLength(1));

    await scheduler.refresh(force: true);
    expect(api.calls, hasLength(2));

    now = now.add(const Duration(minutes: 31));
    await scheduler.refresh();
    expect(api.calls, hasLength(3));
  });

  test('the choices in Settings are what it asks for', () async {
    final choices = NotificationPreferences(preferences);
    await choices.set(NotificationPreferences.briefingsKey, false);
    await choices.set(NotificationPreferences.eveningKey, true);

    await scheduler.refresh(force: true);

    expect(api.calls.single, (false, true, true));
  });

  test('a failure keeps what was scheduled and retries on the next wake',
      () async {
    api.error = Exception('offline');
    await scheduler.refresh();
    expect(port.scheduled, isEmpty);

    api.error = null;
    await scheduler.refresh();
    expect(port.scheduled, hasLength(1));
  });
}
