import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

import 'memory.dart';
import 'task_item.dart';

/// Someone Echo heard about (`GET /api/people`).
@immutable
final class PersonSummary {
  const PersonSummary({
    required this.id,
    required this.name,
    this.role,
    this.about,
    this.lastSeen,
    this.conversationCount = 0,
    this.openTaskCount = 0,
  });

  factory PersonSummary.fromJson(Map<String, dynamic> json) {
    final lastSeen = json['last_seen'];
    return PersonSummary(
      id: json['id'] as String,
      name: (json['name'] as String? ?? '').trim(),
      role: _text(json['role']),
      about: _text(json['about']),
      lastSeen: lastSeen is String ? DateTime.tryParse(lastSeen) : null,
      conversationCount: (json['conversation_count'] as num? ?? 0).toInt(),
      openTaskCount: (json['open_task_count'] as num? ?? 0).toInt(),
    );
  }

  final String id;
  final String name;
  final String? role;

  /// What Echo learned about them, across conversations.
  final String? about;
  final DateTime? lastSeen;
  final int conversationCount;
  final int openTaskCount;

  /// "MR" for "Marco Rossi", "A" for "Ada".
  String get initials {
    final words = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    final first = words.first.characters.first;
    return words.length == 1
        ? first.toUpperCase()
        : '$first${words.last.characters.first}'.toUpperCase();
  }
}

/// `GET /api/people/{id}`: the person and what is linked to them.
@immutable
final class PersonDetail {
  const PersonDetail({
    required this.person,
    required this.conversations,
    required this.tasks,
    required this.events,
  });

  factory PersonDetail.fromJson(Map<String, dynamic> json) {
    return PersonDetail(
      person: PersonSummary.fromJson(json),
      conversations: List.unmodifiable(
        (json['conversations'] as List<dynamic>? ?? const [])
            .map((item) => ConversationCard.fromJson(item as Map<String, dynamic>)),
      ),
      tasks: List.unmodifiable(
        (json['tasks'] as List<dynamic>? ?? const [])
            .map((item) => TaskItem.fromJson(item as Map<String, dynamic>))
            .where((task) => task.name.isNotEmpty),
      ),
      events: List.unmodifiable(
        (json['events'] as List<dynamic>? ?? const [])
            .map((item) => MemoryEntity.fromJson(item as Map<String, dynamic>))
            .where((event) => event.name.isNotEmpty),
      ),
    );
  }

  final PersonSummary person;
  final List<ConversationCard> conversations;
  final List<TaskItem> tasks;
  final List<MemoryEntity> events;
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
