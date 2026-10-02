final class RecentSegment {
  const RecentSegment({
    required this.id,
    required this.receivedAt,
    required this.recordedAt,
    required this.durationMs,
    required this.transcriptionStatus,
    required this.text,
    required this.speaker,
    required this.conversationId,
  });

  final String id;
  final DateTime receivedAt;
  final DateTime recordedAt;
  final int durationMs;
  final String transcriptionStatus;
  final String? text;
  final String? speaker;
  final String? conversationId;

  bool get isPending =>
      transcriptionStatus == 'pending' || transcriptionStatus == 'processing';
  bool get isFailed => transcriptionStatus == 'failed';
  bool get isCompleted => transcriptionStatus == 'completed';

  factory RecentSegment.fromJson(Map<String, dynamic> json) {
    return RecentSegment(
      id: json['id'] as String,
      receivedAt: DateTime.parse(json['received_at'] as String),
      recordedAt: DateTime.parse(json['recorded_at'] as String),
      durationMs: json['duration_ms'] as int,
      transcriptionStatus: json['transcription_status'] as String,
      text: json['text'] as String?,
      speaker: json['speaker'] as String?,
      conversationId: json['conversation_id'] as String?,
    );
  }
}

final class TranscriptionCorrectionResult {
  const TranscriptionCorrectionResult({
    required this.segmentId,
    required this.transcriptionId,
    required this.text,
    required this.speakerLabel,
    required this.updatedAt,
    required this.reanalysisStatus,
  });

  final String segmentId;
  final String transcriptionId;
  final String text;
  final String speakerLabel;
  final DateTime updatedAt;
  final String reanalysisStatus;

  bool get queued => reanalysisStatus == 'queued';
  bool get queueFailed => reanalysisStatus == 'queue_failed';
  bool get unchanged => reanalysisStatus == 'unchanged';

  factory TranscriptionCorrectionResult.fromJson(
    Map<String, dynamic> json,
  ) {
    final speakerLabel = json['speaker_label'] as String;
    final reanalysisStatus = json['reanalysis_status'] as String;
    if (!const {'self', 'other', 'unknown'}.contains(speakerLabel)) {
      throw const FormatException('Invalid speaker_label');
    }
    if (!const {'queued', 'queue_failed', 'unchanged'}
        .contains(reanalysisStatus)) {
      throw const FormatException('Invalid reanalysis_status');
    }

    return TranscriptionCorrectionResult(
      segmentId: json['segment_id'] as String,
      transcriptionId: json['transcription_id'] as String,
      text: json['text'] as String,
      speakerLabel: speakerLabel,
      updatedAt: DateTime.parse(json['updated_at'] as String),
      reanalysisStatus: reanalysisStatus,
    );
  }
}