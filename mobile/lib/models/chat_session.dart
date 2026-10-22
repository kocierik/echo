import 'action_models.dart';

final class ChatSessionSummary {
  const ChatSessionSummary({
    required this.id,
    required this.title,
    required this.messageCount,
    required this.createdAt,
    required this.updatedAt,
    this.kind = 'chat',
  });

  final String id;
  final String? title;
  final int messageCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String kind;

  factory ChatSessionSummary.fromJson(Map<String, dynamic> json) {
    return ChatSessionSummary(
      id: _requiredString(json, 'id'),
      title: _nullableString(json, 'title'),
      messageCount: _requiredInt(json, 'message_count'),
      createdAt: _requiredDateTime(json, 'created_at'),
      updatedAt: _requiredDateTime(json, 'updated_at'),
      kind: json['kind'] == 'voice' ? 'voice' : 'chat',
    );
  }
}

final class ChatSessionMessage {
  const ChatSessionMessage({
    required this.role,
    required this.content,
    this.timestamp,
    this.citations,
    this.sessionId,
    this.pendingAction,
    this.photoId,
    this.source,
    this.when,
    this.routineId,
    this.aboutPhotoId,
  });

  final String role;
  final String content;
  final DateTime? timestamp;
  final List<Map<String, dynamic>>? citations;
  final String? sessionId;
  final PendingAction? pendingAction;

  /// A photo from the wearable camera (`GET /api/photos/{id}/image`).
  final String? photoId;

  /// Where a question came from: "voice", "chat" (typed) or "camera"; null on
  /// messages stored before it was kept.
  final String? source;

  /// A photo's answer: the date or time the photo shows, for "Remind me" (local).
  final DateTime? when;

  /// A routine's run: its instruction and answer.
  final String? routineId;

  /// A follow-up question about a photo, and its answer.
  final String? aboutPhotoId;

  factory ChatSessionMessage.fromJson(Map<String, dynamic> json) {
    final role = _requiredString(json, 'role');
    if (role != 'user' && role != 'assistant') {
      throw const FormatException('role must be user or assistant');
    }

    return ChatSessionMessage(
      role: role,
      content: _requiredString(json, 'content', allowEmpty: true),
      timestamp: _nullableDateTime(json, 'timestamp'),
      citations: _optionalCitations(json),
      sessionId:
          json['session_id'] is String ? json['session_id'] as String : null,
      pendingAction: _optionalPendingAction(json),
      photoId: json['photo_id'] is String ? json['photo_id'] as String : null,
      source: json['source'] is String ? json['source'] as String : null,
      when: json['when'] is String ? DateTime.tryParse(json['when'] as String) : null,
      routineId: json['routine_id'] is String ? json['routine_id'] as String : null,
      aboutPhotoId:
          json['about_photo_id'] is String ? json['about_photo_id'] as String : null,
    );
  }
}

final class ChatSessionDetail {
  ChatSessionDetail({
    required this.id,
    required this.title,
    required List<ChatSessionMessage> messages,
    required this.createdAt,
    required this.updatedAt,
    this.kind = 'chat',
  }) : messages = List.unmodifiable(messages);

  final String id;
  final String? title;

  /// "voice" for the thread with Echo, "chat" for a typed chat of its own.
  final String kind;
  final List<ChatSessionMessage> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ChatSessionDetail.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'];
    if (rawMessages is! List<dynamic>) {
      throw const FormatException('messages must be a list');
    }

    return ChatSessionDetail(
      id: _requiredString(json, 'id'),
      title: _nullableString(json, 'title'),
      messages: rawMessages.map((message) {
        if (message is! Map<String, dynamic>) {
          throw const FormatException('message must be an object');
        }
        return ChatSessionMessage.fromJson(message);
      }).toList(),
      createdAt: _requiredDateTime(json, 'created_at'),
      updatedAt: _requiredDateTime(json, 'updated_at'),
      kind: json['kind'] == 'voice' ? 'voice' : 'chat',
    );
  }
}

String _requiredString(
  Map<String, dynamic> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('$key must be a${allowEmpty ? '' : ' non-empty'} string');
  }
  return value;
}

String? _nullableString(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('$key is missing');
  }
  final value = json[key];
  if (value != null && value is! String) {
    throw FormatException('$key must be a string or null');
  }
  return value as String?;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('$key must be an integer');
  }
  return value;
}

DateTime _requiredDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('$key must be a date string');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$key must be a valid date');
  }
  return parsed;
}

DateTime? _nullableDateTime(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('$key is missing');
  }
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$key must be a date string or null');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$key must be a valid date');
  }
  return parsed;
}

List<Map<String, dynamic>>? _optionalCitations(
  Map<String, dynamic> json,
) {
  if (!json.containsKey('citations') || json['citations'] == null) {
    return null;
  }
  final value = json['citations'];
  if (value is! List<dynamic>) {
    throw const FormatException('citations must be a list or null');
  }
  return List.unmodifiable(value.map((citation) {
    if (citation is! Map<String, dynamic>) {
      throw const FormatException('citation must be an object');
    }
    return Map<String, dynamic>.unmodifiable(citation);
  }));
}

PendingAction? _optionalPendingAction(Map<String, dynamic> json) {
  final value = json['pending_action'];
  if (value == null) return null;
  if (value is! Map<String, dynamic>) {
    throw const FormatException('pending_action must be an object or null');
  }
  return PendingAction.fromJson(value);
}
