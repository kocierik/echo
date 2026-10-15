import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_service.dart';
import 'notification_service.dart';

/// Which notifications the user wants; briefings and promises on, the evening recap off.
final class NotificationPreferences {
  NotificationPreferences(this._preferences);

  static const briefingsKey = 'notify_briefings';
  static const promisesKey = 'notify_promises';
  static const eveningKey = 'notify_evening';

  final SharedPreferences _preferences;

  bool get briefings => _preferences.getBool(briefingsKey) ?? true;
  bool get promises => _preferences.getBool(promisesKey) ?? true;
  bool get evening => _preferences.getBool(eveningKey) ?? false;

  Future<void> set(String key, bool value) => _preferences.setBool(key, value);
}

/// Asks the server what is coming and schedules it on the phone: on each wake (the
/// wearable keeps the app waking through the day), at most every [minInterval].
final class NotificationScheduler {
  NotificationScheduler({
    required NotificationsApi api,
    required NotificationService notifications,
    required NotificationPreferences preferences,
    DateTime Function()? clock,
    this.minInterval = const Duration(minutes: 30),
  })  : _api = api,
        _notifications = notifications,
        _preferences = preferences,
        _clock = clock ?? DateTime.now;

  final NotificationsApi _api;
  final NotificationService _notifications;
  final NotificationPreferences _preferences;
  final DateTime Function() _clock;
  final Duration minInterval;

  DateTime? _lastRefresh;
  Future<void>? _inFlight;

  /// Never throws. [force]: now, whatever the interval (settings changed, app start).
  Future<void> refresh({bool force = false}) {
    final last = _lastRefresh;
    if (!force && last != null && _clock().difference(last) < minInterval) {
      return Future.value();
    }
    return _inFlight ??= _run().whenComplete(() => _inFlight = null);
  }

  Future<void> _run() async {
    try {
      final items = await _api.getUpcomingNotifications(
        briefings: _preferences.briefings,
        promises: _preferences.promises,
        evening: _preferences.evening,
      );
      await _notifications.replaceUpcoming(items, _clock());
      _lastRefresh = _clock();
    } catch (error) {
      // Offline or the server restarting: what was scheduled stays; next wake retries
      debugPrint('[Notifications] refresh failed: $error');
    }
  }
}
