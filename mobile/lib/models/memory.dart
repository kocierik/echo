import 'package:flutter/foundation.dart';

/// A conversation as listed in Memories (`GET /api/conversations`, `/api/search`).
@immutable
final class ConversationCard {
  const ConversationCard({
    required this.id,
    required this.startedAt,
    this.title,
    this.summary,
    this.emoji,
    this.endedAt,
    this.duration = Duration.zero,
    this.segmentCount = 0,
    this.analysisStatus = 'completed',
    this.isOpen = false,
    this.people = const [],
    this.taskCount = 0,
  });

  factory ConversationCard.fromJson(Map<String, dynamic> json) {
    return ConversationCard(
      id: json['id'] as String,
      title: _text(json['title']),
      summary: _text(json['summary']),
      emoji: _text(json['emoji']),
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: _date(json['ended_at']),
      duration: Duration(seconds: (json['duration_s'] as num? ?? 0).toInt()),
      segmentCount: (json['segment_count'] as num? ?? 0).toInt(),
      analysisStatus: json['analysis_status'] as String? ?? 'completed',
      isOpen: json['is_open'] as bool? ?? false,
      people: List<String>.unmodifiable(
        (json['people'] as List<dynamic>? ?? const []).whereType<String>(),
      ),
      taskCount: (json['task_count'] as num? ?? 0).toInt(),
    );
  }

  final String id;
  final String? title;
  final String? summary;
  final String? emoji;
  final DateTime startedAt;
  final DateTime? endedAt;
  final Duration duration;
  final int segmentCount;
  final String analysisStatus;

  /// Still capturing: speech in the next minutes joins this conversation.
  final bool isOpen;
  final List<String> people;
  final int taskCount;

  /// Being transcribed or analysed: the title and summary are not there yet.
  bool get isProcessing =>
      !isOpen && (analysisStatus == 'pending' || analysisStatus == 'processing');
}

/// One Segment of a conversation's transcript.
@immutable
final class TranscriptLine {
  const TranscriptLine({
    required this.segmentId,
    required this.recordedAt,
    required this.status,
    this.text,
    this.speaker,
  });

  factory TranscriptLine.fromJson(Map<String, dynamic> json) {
    return TranscriptLine(
      segmentId: json['segment_id'] as String,
      text: _text(json['text']),
      speaker: json['speaker_label'] as String?,
      status: json['status'] as String? ?? 'completed',
      recordedAt: DateTime.parse(json['recorded_at'] as String),
    );
  }

  final String segmentId;
  final String? text;
  final String? speaker;
  final String status;
  final DateTime recordedAt;

  bool get isPending => status == 'pending' || status == 'processing';
  bool get isFailed => status == 'failed';
}

/// Something Echo extracted: a person, task, event, idea or note.
@immutable
final class MemoryEntity {
  const MemoryEntity({
    required this.id,
    required this.type,
    required this.name,
    this.content,
    this.metadata = const {},
    this.sourceText,
    this.conversationId,
  });

  factory MemoryEntity.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata_'];
    return MemoryEntity(
      id: json['id'] as String,
      type: json['entity_type'] as String? ?? 'note',
      name: (json['name'] as String? ?? '').trim(),
      content: _text(json['content']),
      metadata: metadata is Map<String, dynamic>
          ? Map<String, dynamic>.unmodifiable(metadata)
          : const {},
      sourceText: _text(json['source_text']),
      conversationId: json['conversation_id'] as String?,
    );
  }

  final String id;

  /// person, task, event, idea or note.
  final String type;
  final String name;
  final String? content;
  final Map<String, dynamic> metadata;

  /// The transcript sentence it was extracted from.
  final String? sourceText;
  final String? conversationId;

  bool get done => metadata['done'] == true;

  /// For events: "2026-10-15" and "15:00" when known.
  String? get eventDate => metadata['event_date'] as String?;
  String? get eventTime => metadata['event_time'] as String?;
}

/// `GET /api/conversations/{id}`.
@immutable
final class ConversationDetail {
  const ConversationDetail({
    required this.card,
    required this.lines,
    required this.entities,
  });

  factory ConversationDetail.fromJson(Map<String, dynamic> json) {
    return ConversationDetail(
      card: ConversationCard.fromJson(json),
      lines: List.unmodifiable(
        (json['transcriptions'] as List<dynamic>? ?? const [])
            .map((item) => TranscriptLine.fromJson(item as Map<String, dynamic>)),
      ),
      entities: List.unmodifiable(
        (json['entities'] as List<dynamic>? ?? const [])
            .map((item) => MemoryEntity.fromJson(item as Map<String, dynamic>))
            .where((entity) => entity.name.isNotEmpty),
      ),
    );
  }

  final ConversationCard card;
  final List<TranscriptLine> lines;
  final List<MemoryEntity> entities;

  List<MemoryEntity> ofType(String type) =>
      entities.where((entity) => entity.type == type).toList();
}

/// `GET /api/search`.
@immutable
final class MemorySearchResults {
  const MemorySearchResults({required this.conversations, required this.entities});

  factory MemorySearchResults.fromJson(Map<String, dynamic> json) {
    return MemorySearchResults(
      conversations: List.unmodifiable(
        (json['conversations'] as List<dynamic>? ?? const [])
            .map((item) => ConversationCard.fromJson(item as Map<String, dynamic>)),
      ),
      entities: List.unmodifiable(
        (json['entities'] as List<dynamic>? ?? const [])
            .map((item) => MemoryEntity.fromJson(item as Map<String, dynamic>))
            .where((entity) => entity.name.isNotEmpty),
      ),
    );
  }

  final List<ConversationCard> conversations;
  final List<MemoryEntity> entities;

  bool get isEmpty => conversations.isEmpty && entities.isEmpty;
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _date(Object? value) => value is String ? DateTime.tryParse(value) : null;
