import 'package:flutter/foundation.dart';

import 'memory.dart';

/// A task extracted from a conversation (`GET /api/entities/tasks`).
@immutable
final class TaskItem {
  const TaskItem({
    required this.id,
    required this.name,
    this.dueDate,
    this.metadata = const {},
    this.sourceText,
    this.conversationId,
    this.createdAt,
  });

  factory TaskItem.fromJson(Map<String, dynamic> json) {
    final rawMetadata = json['metadata_'];
    final metadata = rawMetadata is Map<String, dynamic>
        ? Map<String, dynamic>.unmodifiable(rawMetadata)
        : const <String, dynamic>{};
    final dueDate = metadata['due_date'];
    final source = json['source_text'];
    final createdAt = json['created_at'];
    return TaskItem(
      id: json['id'] as String,
      name: (json['name'] as String? ?? '').trim(),
      dueDate: dueDate is String ? DateTime.tryParse(dueDate) : null,
      metadata: metadata,
      sourceText: source is String && source.trim().isNotEmpty ? source.trim() : null,
      conversationId: json['conversation_id'] as String?,
      createdAt: createdAt is String ? DateTime.tryParse(createdAt) : null,
    );
  }

  /// A task listed inside a conversation detail.
  factory TaskItem.fromEntity(MemoryEntity entity) {
    final dueDate = entity.metadata['due_date'];
    return TaskItem(
      id: entity.id,
      name: entity.name,
      dueDate: dueDate is String ? DateTime.tryParse(dueDate) : null,
      metadata: entity.metadata,
      sourceText: entity.sourceText,
      conversationId: entity.conversationId,
    );
  }

  final String id;
  final String name;

  /// The day it is due (a date without time, as extracted).
  final DateTime? dueDate;

  /// Full entity metadata: the backend replaces it on update, so changing a
  /// task must send all of it back.
  final Map<String, dynamic> metadata;

  /// The transcript sentence the task was extracted from.
  final String? sourceText;
  final String? conversationId;
  final DateTime? createdAt;

  /// Something the user committed to someone ("ti mando il preventivo").
  bool get isPromise => metadata['promise'] == true;

  /// Whom it was promised to, when known.
  String? get promiseTo {
    final to = metadata['promise_to'];
    return to is String && to.trim().isNotEmpty ? to.trim() : null;
  }

  /// Something someone promised the user ("il preventivo te lo mando io domani").
  bool get isExpected => metadata['expected'] == true;

  /// Who is to do it, when known.
  String? get expectedFrom {
    final from = metadata['expected_from'];
    return from is String && from.trim().isNotEmpty ? from.trim() : null;
  }

  bool get done => metadata['done'] == true;

  Map<String, dynamic> metadataWithDone(bool done) => {...metadata, 'done': done};

  TaskItem copyWithDone(bool done) => TaskItem(
        id: id,
        name: name,
        dueDate: dueDate,
        metadata: Map.unmodifiable(metadataWithDone(done)),
        sourceText: sourceText,
        conversationId: conversationId,
        createdAt: createdAt,
      );
}
