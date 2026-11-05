import 'package:flutter/foundation.dart';

/// Who a chat is with: an assistant's name and emoji (`/api/chat-sessions`).
@immutable
final class ChatAssistant {
  const ChatAssistant({required this.id, required this.name, required this.emoji});

  /// From a chat session's `assistant_*` fields; null for plain Echo.
  static ChatAssistant? fromSession(Map<String, dynamic> json) {
    final id = json['assistant_id'];
    if (id is! String) return null;
    return ChatAssistant(
      id: id,
      name: json['assistant_name'] as String? ?? '',
      emoji: json['assistant_emoji'] as String? ?? '🤖',
    );
  }

  final String id;
  final String name;
  final String emoji;

  /// "🥗 Dieta"
  String get label => '$emoji $name';
}

/// Echo for one part of the user's life (`/api/assistants`): its own instructions,
/// notes and documents.
@immutable
final class Assistant {
  const Assistant({
    required this.id,
    required this.name,
    required this.emoji,
    required this.instructions,
    required this.notes,
    required this.documentIds,
  });

  factory Assistant.fromJson(Map<String, dynamic> json) => Assistant(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        emoji: json['emoji'] as String? ?? '🤖',
        instructions: json['instructions'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        documentIds: List.unmodifiable([
          for (final id in json['document_ids'] as List<dynamic>? ?? const [])
            if (id is String) id,
        ]),
      );

  /// Limits the server enforces.
  static const maxName = 40;
  static const maxInstructions = 2000;
  static const maxNotes = 3000;
  static const maxCount = 10;

  final String id;
  final String name;
  final String emoji;
  final String instructions;

  /// What it keeps about its topic; it adds and removes lines itself.
  final String notes;

  /// Its documents; empty: all of the user's.
  final List<String> documentIds;

  ChatAssistant get forChat => ChatAssistant(id: id, name: name, emoji: emoji);
}

/// A starting point for a new assistant (work, diet, sleep), in the account's language.
@immutable
final class AssistantTemplate {
  const AssistantTemplate({
    required this.key,
    required this.name,
    required this.emoji,
    required this.instructions,
  });

  factory AssistantTemplate.fromJson(Map<String, dynamic> json) => AssistantTemplate(
        key: json['key'] as String,
        name: json['name'] as String? ?? '',
        emoji: json['emoji'] as String? ?? '🤖',
        instructions: json['instructions'] as String? ?? '',
      );

  final String key;
  final String name;
  final String emoji;
  final String instructions;
}

/// What the editor saves: a new assistant, or every field of one.
@immutable
final class AssistantDraft {
  const AssistantDraft({
    required this.name,
    required this.emoji,
    required this.instructions,
    this.notes = '',
    this.documentIds = const [],
  });

  final String name;
  final String emoji;
  final String instructions;
  final String notes;
  final List<String> documentIds;

  /// Echo's proposal from the answers (no documents yet).
  factory AssistantDraft.fromJson(Map<String, dynamic> json) => AssistantDraft(
        name: json['name'] as String? ?? '',
        emoji: json['emoji'] as String? ?? '🤖',
        instructions: json['instructions'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'emoji': emoji,
        'instructions': instructions,
        'notes': notes,
        'document_ids': documentIds,
      };
}
