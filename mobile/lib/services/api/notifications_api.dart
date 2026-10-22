import '../../models/today_insights.dart';
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

/// Today's "coming up" card: the phone calendar's next events, matched with the memory.
abstract interface class ComingUpApi {
  Future<ComingUp?> comingUp(List<Map<String, Object?>> phoneEvents);
}

mixin NotificationEndpoints on ApiClient implements NotificationsApi, ComingUpApi {
  @override
  Future<ComingUp?> comingUp(List<Map<String, Object?>> phoneEvents) async {
    final response = await post(
      '/api/notifications/coming-up',
      body: {'phone_events': phoneEvents},
    );
    return parse(response.data, (data) => ComingUp.fromJson(data as Map<String, dynamic>));
  }

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
