import '../../models/upcoming_notification.dart';
import 'api_client.dart';

/// The few notifications worth scheduling (briefings, promises, evening recap).
abstract interface class NotificationsApi {
  /// [phoneEvents]: the iPhone calendar's next events, for briefings before them too.
  Future<List<UpcomingNotification>> getUpcomingNotifications({
    required bool briefings,
    required bool promises,
    required bool evening,
    List<Map<String, Object?>> phoneEvents = const [],
  });
}

mixin NotificationEndpoints on ApiClient implements NotificationsApi {
  @override
  Future<List<UpcomingNotification>> getUpcomingNotifications({
    required bool briefings,
    required bool promises,
    required bool evening,
    List<Map<String, Object?>> phoneEvents = const [],
  }) async {
    final response = await post('/api/notifications/upcoming', body: {
      'briefings': briefings,
      'promises': promises,
      'evening': evening,
      'phone_events': phoneEvents,
    });
    return parse(response.data, (data) {
      final items =
          (data as Map<String, dynamic>)['notifications'] as List<dynamic>;
      return items
          .map((item) =>
              UpcomingNotification.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }
}
