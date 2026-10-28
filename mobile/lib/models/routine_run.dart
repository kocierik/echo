import 'package:flutter/foundation.dart';

/// A web page a routine's answer cites. [url] is null when the link is not http(s).
@immutable
final class RoutineSource {
  const RoutineSource({required this.title, this.url});

  factory RoutineSource.fromJson(Map<String, dynamic> json) {
    final raw = json['url'];
    final uri = raw is String ? Uri.tryParse(raw) : null;
    final web = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    final title = json['title'] is String ? json['title'] as String : '';
    return RoutineSource(
      title: title.isNotEmpty ? title : (web ? uri.host : ''),
      url: web ? uri : null,
    );
  }

  final String title;
  final Uri? url;
}

/// One run of a routine (`GET /api/routine-runs`): what it found, or that it had nothing
/// to say ("nothing"), could not run ("failed") or was missed ("skipped").
@immutable
final class RoutineRun {
  const RoutineRun({
    required this.id,
    required this.routineId,
    required this.instruction,
    required this.mode,
    required this.scheduleText,
    required this.ranAt,
    required this.status,
    this.text,
    this.sources = const [],
  });

  factory RoutineRun.fromJson(Map<String, dynamic> json) {
    final sources = json['sources'];
    return RoutineRun(
      id: json['id'] as String,
      routineId: json['routine_id'] as String,
      instruction: json['instruction'] as String? ?? '',
      mode: json['mode'] as String? ?? 'always',
      scheduleText: json['schedule_text'] as String? ?? '',
      ranAt: DateTime.parse(json['ran_at'] as String).toLocal(),
      status: json['status'] as String,
      text: json['text'] as String?,
      sources: sources is List<dynamic>
          ? List.unmodifiable([
              for (final source in sources)
                if (source is Map<String, dynamic>) RoutineSource.fromJson(source),
            ])
          : const [],
    );
  }

  final String id;
  final String routineId;

  /// The routine's request, in the user's words.
  final String instruction;

  /// "always", "only_if" or "only_new".
  final String mode;

  /// "Every day at 07:00".
  final String scheduleText;

  /// Local time.
  final DateTime ranAt;

  /// "reported", "nothing", "failed" or "skipped".
  final String status;

  /// The answer in full; null for "nothing" and "skipped".
  final String? text;
  final List<RoutineSource> sources;

  /// Something to read, and to ask Echo about.
  bool get hasText => text != null && text!.isNotEmpty;
}

/// A page of runs, newest first; [nextBefore] asks for the next one (null on the last).
@immutable
final class RoutineRunPage {
  const RoutineRunPage({required this.items, this.nextBefore});

  factory RoutineRunPage.fromJson(Map<String, dynamic> json) {
    final next = json['next_before'];
    return RoutineRunPage(
      items: List.unmodifiable([
        for (final item in json['items'] as List<dynamic>)
          RoutineRun.fromJson(item as Map<String, dynamic>),
      ]),
      nextBefore: next is String ? DateTime.tryParse(next)?.toLocal() : null,
    );
  }

  final List<RoutineRun> items;
  final DateTime? nextBefore;
}
