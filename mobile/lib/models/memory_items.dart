import 'package:flutter/foundation.dart';

/// A sentence about the user (`/api/facts`): kept ones are in every answer, suggested
/// ones wait for Keep or Discard.
@immutable
final class UserFact {
  const UserFact({
    required this.id,
    required this.text,
    required this.status,
    required this.source,
    this.conversationId,
  });

  factory UserFact.fromJson(Map<String, dynamic> json) => UserFact(
        id: json['id'] as String,
        text: json['text'] as String? ?? '',
        status: json['status'] as String? ?? 'kept',
        source: json['source'] as String? ?? 'you',
        conversationId: json['conversation_id'] as String?,
      );

  final String id;
  final String text;

  /// "kept" or "suggested".
  final String status;

  /// "you", "echo" (asked by voice or chat) or "conversation" (Echo noticed it).
  final String source;

  /// The conversation a suggestion came from.
  final String? conversationId;
}

/// About you: the kept facts and Echo's suggestions.
@immutable
final class UserFacts {
  const UserFacts({required this.kept, required this.suggestions});

  factory UserFacts.fromJson(Map<String, dynamic> json) {
    List<UserFact> read(Object? items) => List.unmodifiable([
          for (final item in items as List<dynamic>? ?? const [])
            if (item is Map<String, dynamic>) UserFact.fromJson(item),
        ]);
    return UserFacts(kept: read(json['kept']), suggestions: read(json['suggestions']));
  }

  final List<UserFact> kept;
  final List<UserFact> suggestions;
}

/// A document the user added (`/api/documents`): its text, never the file.
@immutable
final class UserDocument {
  const UserDocument({
    required this.id,
    required this.title,
    required this.kind,
    required this.sizeBytes,
    required this.status,
    required this.wordCount,
    this.error,
    this.pages,
    this.preview,
  });

  factory UserDocument.fromJson(Map<String, dynamic> json) => UserDocument(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        kind: json['kind'] as String? ?? 'txt',
        sizeBytes: (json['size_bytes'] as num? ?? 0).toInt(),
        status: json['status'] as String? ?? 'processing',
        wordCount: (json['word_count'] as num? ?? 0).toInt(),
        error: json['error'] as String?,
        pages: (json['pages'] as num?)?.toInt(),
        preview: json['preview'] as String?,
      );

  final String id;
  final String title;

  /// "pdf", "docx", "txt" or "md".
  final String kind;
  final int sizeBytes;

  /// "processing", "ready" or "failed".
  final String status;
  final int wordCount;

  /// Why it failed.
  final String? error;
  final int? pages;

  /// The beginning of its text (`GET /api/documents/{id}` only).
  final String? preview;

  bool get isProcessing => status == 'processing';
}
