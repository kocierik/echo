import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../models/upcoming_notification.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

abstract interface class NotificationPort {
  Future<void> initialize();
  Future<bool> requestPermission();
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required Duration delay,
    String? payload,
  });
  Future<void> cancel(int id);
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  });
}

final class NotificationService {
  NotificationService(this._port);

  static const int disconnectId = 100;
  static const int lossId = 101;
  static const int uploadFailureId = 102;
  static const int savePlaceId = 103;
  static const int photoTakenId = 104;
  static const int voiceAnswerBaseId = 200;
  static const int voiceAnswerIdCount = 50;
  static const String voicePayloadPrefix = 'voice:';

  /// A routine's result: a tap opens Ask on Routines.
  static const String routinesPayloadPrefix = 'routines:';

  /// Who is in front of you: a few slots in turn, so two people do not replace each other.
  static const int personBriefBaseId = 400;
  static const int personBriefIdCount = 10;

  /// Briefings, promises and the evening recap: rescheduled as a whole on each refresh.
  static const int upcomingBaseId = 300;
  static const int upcomingIdCount = 10;

  final NotificationPort _port;
  bool _disconnectScheduled = false;
  int _nextPersonBrief = 0;

  Future<void> initialize() => _port.initialize();

  Future<bool> requestPermission() => _port.requestPermission();

  Future<void> scheduleDisconnected() async {
    if (_disconnectScheduled) return;
    _disconnectScheduled = true;
    try {
      await _port.schedule(
        id: disconnectId,
        title: 'Echo disconnected',
        body: 'Echo has been disconnected for two minutes.',
        delay: const Duration(minutes: 2),
      );
    } catch (_) {
      _disconnectScheduled = false;
      rethrow;
    }
  }

  Future<void> cancelDisconnected() async {
    if (!_disconnectScheduled) return;
    _disconnectScheduled = false;
    await _port.cancel(disconnectId);
  }

  /// The wearable's memory filled up while its speech could not be synced, and it made
  /// room by dropping the oldest. [droppedCount]: since the last such notification.
  Future<void> showLoss(int droppedCount) => _port.show(
        id: lossId,
        title: "Some speech wasn't saved",
        body: "Echo's memory was full: "
            '${droppedCount == 1 ? '1 recording was' : '$droppedCount recordings were'} lost. '
            'Keep your phone near Echo, signed in, so it can sync.',
      );

  Future<void> showUploadFailure() => _port.show(
        id: uploadFailureId,
        title: 'Upload needs attention',
        body: 'Echo could not upload recent audio after several attempts.',
      );

  /// A thing was saved while Echo was in the background, where the phone gives no
  /// position: opening Echo adds the place.
  Future<void> showSavePlace() => _port.show(
        id: savePlaceId,
        title: 'Open Echo to save the place',
        body: 'Echo saved it without the place: open the app now to add where you are.',
      );

  /// The wearable took a photo while Echo was in the background: a tap opens Ask, where
  /// its answer arrives.
  Future<void> showPhotoTaken() => _port.show(
        id: photoTakenId,
        title: '📷 Photo taken',
        body: 'Echo is looking at it: the answer will be in Ask.',
        payload: voicePayloadPrefix,
      );

  Future<void> showVoiceAnswer(
    String preview, {
    String? sessionId,
    int id = voiceAnswerBaseId,
  }) =>
      _port.show(
        id: id,
        title: 'Echo',
        body: preview,
        payload: '$voicePayloadPrefix${sessionId ?? ''}',
      );

  /// What a routine found, or that it could not run; shares the voice answers' slots.
  Future<void> showRoutineRun(
    String preview, {
    required String runId,
    required int id,
  }) =>
      _port.show(
        id: id,
        title: 'Echo',
        body: preview,
        payload: '$routinesPayloadPrefix$runId',
      );

  /// Someone the user knows started talking (the server's `person_brief`): a tap opens
  /// their page.
  Future<void> showPersonBrief({
    required String personId,
    required String title,
    required String body,
  }) {
    final id = personBriefBaseId + _nextPersonBrief;
    _nextPersonBrief = (_nextPersonBrief + 1) % personBriefIdCount;
    return _port.show(id: id, title: title, body: body, payload: 'person:$personId');
  }

  /// Replaces what was scheduled before with [items] (past ones are skipped).
  Future<void> replaceUpcoming(List<UpcomingNotification> items, DateTime now) async {
    for (var i = 0; i < upcomingIdCount; i++) {
      await _port.cancel(upcomingBaseId + i);
    }
    var slot = 0;
    for (final item in items) {
      if (slot >= upcomingIdCount) break;
      final delay = item.fireAt.difference(now);
      if (delay <= Duration.zero) continue;
      await _port.schedule(
        id: upcomingBaseId + slot++,
        title: item.title,
        body: item.body,
        delay: delay,
        payload: item.target,
      );
    }
  }

  Future<void> segmentCompleted() async {}
}

final class FlutterLocalNotificationPort implements NotificationPort {
  FlutterLocalNotificationPort({
    FlutterLocalNotificationsPlugin? plugin,
    this.onSelect,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// Called with the notification payload when the user taps a notification.
  void Function(String payload)? onSelect;

  static const _notificationDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'echo_status',
      'Echo status',
      channelDescription: 'Wearable connection and upload status',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> initialize() async {
    timezone_data.initializeTimeZones();
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null) onSelect?.call(payload);
      },
    );
  }

  /// The payload of the notification that launched the app (cold start), if
  /// any.
  Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse?.payload;
  }

  @override
  Future<bool> requestPermission() async {
    final iosGranted = await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    final androidGranted = await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    return iosGranted ?? androidGranted ?? false;
  }

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required Duration delay,
    String? payload,
  }) {
    return _plugin.zonedSchedule(
      id,
      title,
      body,
      timezone.TZDateTime.now(timezone.local).add(delay),
      _notificationDetails,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id);

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) {
    return _plugin.show(id, title, body, _notificationDetails,
        payload: payload);
  }
}