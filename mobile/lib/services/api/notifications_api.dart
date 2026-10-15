import '../../models/upcoming_notification.dart';
import 'api_client.dart';

/// The few notifications worth scheduling (briefings, promises, evening recap).
abstract interface class NotificationsApi {
  Future<List<UpcomingNotification>> getUpcomingNotifications({
    required bool briefings,
    required bool promises,
    required bool evening,
  });
}

mixin NotificationEndpoints on ApiClient implements NotificationsApi {
  @override
  Future<List<UpcomingNotification>> getUpcomingNotifications({
    required bool briefings,
    required bool promises,
    required bool evening,
  }) async {
    final response = await getCached(
      '/api/notifications/upcoming?briefings=$briefings&promises=$promises&evening=$evening',
    );
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
