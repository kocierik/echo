final class ChatSessionSummary {
  const ChatSessionSummary({
    required this.id,
    required this.title,
    required this.messageCount,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String? title;
  final int messageCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ChatSessionSummary.fromJson(Map<String, dynamic> json) {
    return ChatSessionSummary(
      id: _requiredString(json, 'id'),
      title: _nullableString(json, 'title'),
      messageCount: _requiredInt(json, 'message_count'),
      createdAt: _requiredDateTime(json, 'created_at'),
      updatedAt: _requiredDateTime(json, 'updated_at'),
    );
  }
}

final class ChatSessionMessage {
  const ChatSessionMessage({
    required this.role,
    required this.content,
    this.timestamp,
    this.citations,
  });

  final String role;
  final String content;
  final DateTime? timestamp;
  final List<Map<String, dynamic>>? citations;

  factory ChatSessionMessage.fromJson(Map<String, dynamic> json) {
    final role = _requiredString(json, 'role');
    if (role != 'user' && role != 'assistant') {
      throw FormatException('role must be user or assistant');
    }

    return ChatSessionMessage(
      role: role,
      content: _requiredString(json, 'content', allowEmpty: true),
      timestamp: _nullableDateTime(json, 'timestamp'),
      citations: _optionalCitations(json),
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
  }) : messages = List.unmodifiable(messages);

  final String id;
  final String? title;
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