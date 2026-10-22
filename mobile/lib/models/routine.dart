import 'package:flutter/foundation.dart';

/// Something Echo does on its own at a time the user asked for (`GET /api/routines`).
/// Created by asking Echo; here it is seen, paused, resumed or deleted.
@immutable
final class Routine {
  const Routine({
    required this.id,
    required this.instruction,
    required this.scheduleText,
    required this.active,
    required this.nextRunAt,
    this.lastRunAt,
    this.lastStatus,
    this.lastAnswer,
  });

  factory Routine.fromJson(Map<String, dynamic> json) {
    DateTime? time(String key) =>
        json[key] is String ? DateTime.tryParse(json[key] as String)?.toLocal() : null;
    return Routine(
      id: json['id'] as String,
      instruction: json['instruction'] as String? ?? '',
      scheduleText: json['schedule_text'] as String? ?? '',
      active: json['active'] as bool? ?? true,
      nextRunAt: time('next_run_at') ?? DateTime.now(),
      lastRunAt: time('last_run_at'),
      lastStatus: json['last_status'] as String?,
      lastAnswer: json['last_answer'] as String?,
    );
  }

  final String id;

  /// What it does, in the user's words: "dimmi che tempo fa a Milano".
  final String instruction;

  /// When, in words: "Every day at 07:00".
  final String scheduleText;
  final bool active;
  final DateTime nextRunAt;
  final DateTime? lastRunAt;

  /// "ok", "failed" or "skipped" (missed while the server was down); null before a run.
  final String? lastStatus;
  final String? lastAnswer;

  Routine copyWith({bool? active, DateTime? nextRunAt}) => Routine(
        id: id,
        instruction: instruction,
        scheduleText: scheduleText,
        active: active ?? this.active,
        nextRunAt: nextRunAt ?? this.nextRunAt,
        lastRunAt: lastRunAt,
        lastStatus: lastStatus,
        lastAnswer: lastAnswer,
      );
}
