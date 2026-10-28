import 'chat_session.dart';

/// A Composio toolkit the user can connect or disconnect.
final class Toolkit {
  const Toolkit({
    required this.slug,
    required this.name,
    required this.description,
    required this.connected,
  });

  final String slug;
  final String name;
  final String description;
  final bool connected;

  factory Toolkit.fromJson(Map<String, dynamic> json) {
    final connected = json['connected'];
    if (connected is! bool) {
      throw const FormatException('connected must be a boolean');
    }
    return Toolkit(
      slug: _string(json, 'slug'),
      name: _string(json, 'name'),
      description: _string(json, 'description', allowEmpty: true),
      connected: connected,
    );
  }
}

/// An action awaiting the user's confirmation. [status] and [expiresAt] are
/// absent when the source JSON (e.g. a stored session message) lacks them.
final class PendingAction {
  const PendingAction({
    required this.id,
    required this.summary,
    this.status,
    this.expiresAt,
    this.app,
    this.source,
  });

  final String id;
  final String summary;
  final String? status;
  final DateTime? expiresAt;

  /// "Gmail", "Google Calendar"… (listed actions only).
  final String? app;

  /// "voice" or "chat" (listed actions only).
  final String? source;

  factory PendingAction.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    if (status != null && status is! String) {
      throw const FormatException('status must be a string or null');
    }
    final expires = json['expires_at'];
    DateTime? expiresAt;
    if (expires != null) {
      if (expires is! String) {
        throw const FormatException('expires_at must be a date string');
      }
      expiresAt = DateTime.tryParse(expires);
      if (expiresAt == null) {
        throw const FormatException('expires_at must be a valid date');
      }
    }
    final app = json['app'];
    final source = json['source'];
    return PendingAction(
      id: _string(json, 'id'),
      summary: _string(json, 'summary', allowEmpty: true),
      status: status as String?,
      expiresAt: expiresAt,
      app: app is String ? app : null,
      source: source is String ? source : null,
    );
  }

  PendingAction copyWith({String? status}) => PendingAction(
        id: id,
        summary: summary,
        status: status ?? this.status,
        expiresAt: expiresAt,
        app: app,
        source: source,
      );
}

/// Result of confirming a pending action: [status] is `executed`, `failed`
/// or `unknown` (the request timed out: it may or may not have happened);
/// [message] is the (possibly localized) text to show the user.
final class ConfirmResult {
  const ConfirmResult({required this.status, required this.message});

  static const statuses = {'executed', 'failed', 'unknown'};

  final String status;
  final String message;

  bool get failed => status == 'failed';
  bool get unknown => status == 'unknown';

  factory ConfirmResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    if (!statuses.contains(status)) {
      throw const FormatException('status must be executed, failed or unknown');
    }
    return ConfirmResult(
      status: status as String,
      message: _string(json, 'message', allowEmpty: true),
    );
  }
}

final class ActionLogEntry {
  const ActionLogEntry({
    required this.tool,
    required this.toolkit,
    required this.argumentsSummary,
    required this.outcome,
    required this.error,
    required this.createdAt,
  });

  final String tool;
  final String toolkit;
  final String argumentsSummary;
  final String outcome;
  final String? error;
  final DateTime createdAt;

  factory ActionLogEntry.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    if (error != null && error is! String) {
      throw const FormatException('error must be a string or null');
    }
    final created = json['created_at'];
    final createdAt = created is String ? DateTime.tryParse(created) : null;
    if (createdAt == null) {
      throw const FormatException('created_at must be a valid date');
    }
    return ActionLogEntry(
      tool: _string(json, 'tool'),
      toolkit: _string(json, 'toolkit', allowEmpty: true),
      argumentsSummary: _string(json, 'arguments_summary', allowEmpty: true),
      outcome: _string(json, 'outcome'),
      error: error as String?,
      createdAt: createdAt,
    );
  }
}

final class VoiceUpdates {
  VoiceUpdates({
    required List<ChatSessionMessage> messages,
    required this.now,
    List<RoutineRunUpdate> routineRuns = const [],
  })  : messages = List<ChatSessionMessage>.unmodifiable(messages),
        routineRuns = List<RoutineRunUpdate>.unmodifiable(routineRuns);

  final List<ChatSessionMessage> messages;
  final DateTime now;

  /// Routine runs since the last check that reported something or failed.
  final List<RoutineRunUpdate> routineRuns;

  factory VoiceUpdates.fromJson(Map<String, dynamic> json) {
    final raw = json['messages'];
    if (raw is! List<dynamic>) {
      throw const FormatException('messages must be a list');
    }
    final nowValue = json['now'];
    final now = nowValue is String ? DateTime.tryParse(nowValue) : null;
    if (now == null) {
      throw const FormatException('now must be a valid date');
    }
    return VoiceUpdates(
      messages: raw.map((message) {
        if (message is! Map<String, dynamic>) {
          throw const FormatException('message must be an object');
        }
        return ChatSessionMessage.fromJson(message);
      }).toList(),
      now: now,
      routineRuns: [
        for (final run in json['routine_runs'] as List<dynamic>? ?? const [])
          if (run is Map<String, dynamic>) RoutineRunUpdate.fromJson(run),
      ],
    );
  }
}

/// A routine run the phone notifies: what it found, or that it could not run.
final class RoutineRunUpdate {
  const RoutineRunUpdate({
    required this.id,
    required this.routineId,
    required this.status,
    required this.ranAt,
    this.text,
  });

  factory RoutineRunUpdate.fromJson(Map<String, dynamic> json) => RoutineRunUpdate(
        id: _string(json, 'id'),
        routineId: _string(json, 'routine_id'),
        status: _string(json, 'status'),
        ranAt: DateTime.parse(_string(json, 'ran_at')).toLocal(),
        text: json['text'] is String ? json['text'] as String : null,
      );

  final String id;
  final String routineId;

  /// "reported" or "failed".
  final String status;
  final DateTime ranAt;
  final String? text;
}

String _string(
  Map<String, dynamic> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('$key must be a string');
  }
  return value;
}
