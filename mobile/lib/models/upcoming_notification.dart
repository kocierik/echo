import 'package:flutter/foundation.dart';

/// A notification the server computed for the phone to schedule.
@immutable
final class UpcomingNotification {
  const UpcomingNotification({
    required this.key,
    required this.kind,
    required this.fireAt,
    required this.title,
    required this.body,
    required this.target,
  });

  factory UpcomingNotification.fromJson(Map<String, dynamic> json) => UpcomingNotification(
        key: json['key'] as String,
        kind: json['kind'] as String,
        fireAt: DateTime.parse(json['fire_at'] as String),
        title: json['title'] as String,
        body: json['body'] as String,
        target: json['target'] as String,
      );

  final String key;

  /// "briefing", "promises" or "evening".
  final String kind;
  final DateTime fireAt;
  final String title;
  final String body;

  /// What a tap opens: "person:<id>", "tasks" or "today".
  final String target;
}
