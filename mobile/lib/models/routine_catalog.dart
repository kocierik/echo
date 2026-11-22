/// A ready-made routine of the catalog, in the user's language (GET /api/routines/catalog).
final class CatalogRoutine {
  const CatalogRoutine({
    required this.key,
    required this.emoji,
    required this.title,
    required this.summary,
    required this.instruction,
    required this.example,
    required this.schedule,
    required this.scheduleText,
    this.routineId,
  });

  factory CatalogRoutine.fromJson(Map<String, dynamic> json) => CatalogRoutine(
        key: json['key'] as String,
        emoji: json['emoji'] as String? ?? '⏰',
        title: json['title'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        instruction: json['instruction'] as String? ?? '',
        example: json['example'] as String? ?? '',
        schedule: (json['schedule'] as Map?)?.cast<String, dynamic>() ?? const {},
        scheduleText: json['schedule_text'] as String? ?? '',
        routineId: json['routine_id'] as String?,
      );

  final String key;
  final String emoji;
  final String title;
  final String summary;
  final String instruction;

  /// What a run could say, shown before adding it.
  final String example;

  /// {kind: daily | weekdays | weekly | monthly, time: "HH:MM", days?, day_of_month?}
  final Map<String, dynamic> schedule;
  final String scheduleText;

  /// Already added: that routine.
  final String? routineId;

  bool get added => routineId != null;
  String get kind => schedule['kind'] as String? ?? 'daily';
  String get time => schedule['time'] as String? ?? '09:00';
}
