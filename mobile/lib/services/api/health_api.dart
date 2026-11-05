import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// A day of the iPhone's Health app, as Apple's Shortcuts sent it (docs/HEALTH-SHORTCUT.md).
@immutable
final class HealthDayInfo {
  const HealthDayInfo({
    required this.day,
    this.sleepMinutes,
    this.steps,
    this.distanceKm,
    this.exerciseMinutes,
    this.workouts,
  });

  factory HealthDayInfo.fromJson(Map<String, dynamic> json) => HealthDayInfo(
        day: DateTime.parse(json['day'] as String),
        sleepMinutes: (json['sleep_minutes'] as num?)?.toInt(),
        steps: (json['steps'] as num?)?.toInt(),
        distanceKm: (json['distance_km'] as num?)?.toDouble(),
        exerciseMinutes: (json['exercise_minutes'] as num?)?.toInt(),
        workouts: json['workouts'] as String?,
      );

  final DateTime day;
  final int? sleepMinutes;
  final int? steps;
  final double? distanceKm;
  final int? exerciseMinutes;
  final String? workouts;
}

/// The key the shortcut posts with, shown once, and where it posts after the server.
typedef ShortcutKey = ({String apiKey, String path});

/// Profile → Health.
abstract interface class HealthApi {
  /// The last two weeks received, newest first.
  Future<List<HealthDayInfo>> healthDays();

  /// A new key for the shortcut; the one made before stops working.
  Future<ShortcutKey> makeHealthKey();

  /// Every day kept, and the shortcut's key.
  Future<void> forgetHealth();

  /// The server's address, for the shortcut's URL.
  Future<String> getServerUrl();
}

mixin HealthEndpoints on ApiClient implements HealthApi {
  @override
  Future<List<HealthDayInfo>> healthDays() async {
    final response = await get('/api/health/days');
    return parse(
        response.data,
        (data) => [
              for (final item in (data as Map<String, dynamic>)['days'] as List<dynamic>)
                if (item is Map<String, dynamic>) HealthDayInfo.fromJson(item),
            ]);
  }

  @override
  Future<ShortcutKey> makeHealthKey() async {
    final response = await post('/api/health/key');
    return parse(response.data, (data) {
      final json = data as Map<String, dynamic>;
      return (apiKey: json['api_key'] as String, path: json['path'] as String);
    });
  }

  @override
  Future<void> forgetHealth() => delete('/api/health');
}
