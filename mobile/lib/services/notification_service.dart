import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
  static const int voiceAnswerBaseId = 200;
  static const int voiceAnswerIdCount = 50;
  static const String voicePayloadPrefix = 'voice:';

  final NotificationPort _port;
  bool _disconnectScheduled = false;

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

  Future<void> showLoss(int droppedCount) => _port.show(
        id: lossId,
        title: 'Audio segments lost',
        body: '$droppedCount audio segments were dropped by the wearable.',
      );

  Future<void> showUploadFailure() => _port.show(
        id: uploadFailureId,
        title: 'Upload needs attention',
        body: 'Echo could not upload recent audio after several attempts.',
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