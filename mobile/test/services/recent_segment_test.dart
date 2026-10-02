import 'package:echo_app/models/segment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses pending and completed recent segments', () {
    final pending = RecentSegment.fromJson({
      'id': 'segment-pending',
      'received_at': '2026-08-02T20:00:01Z',
      'recorded_at': '2026-08-02T20:00:00Z',
      'duration_ms': 1500,
      'transcription_status': 'processing',
      'text': null,
      'speaker': 'unknown',
      'conversation_id': null,
    });
    final completed = RecentSegment.fromJson({
      'id': 'segment-completed',
      'received_at': '2026-08-02T20:01:01Z',
      'recorded_at': '2026-08-02T20:01:00Z',
      'duration_ms': 2200,
      'transcription_status': 'completed',
      'text': '[Tu] Prenota il treno',
      'speaker': 'self',
      'conversation_id': 'conversation-id',
    });

    expect(pending.isPending, isTrue);
    expect(pending.text, isNull);
    expect(completed.isPending, isFalse);
    expect(completed.text, '[Tu] Prenota il treno');
    expect(completed.conversationId, 'conversation-id');
    expect(completed.recordedAt.isUtc, isTrue);
  });

  test('parses transcription correction states strictly', () {
    final queued = TranscriptionCorrectionResult.fromJson({
      'segment_id': 'segment-1',
      'transcription_id': 'transcription-1',
      'text': 'Corrected memory',
      'speaker_label': 'self',
      'updated_at': '2026-10-02T12:00:00Z',
      'reanalysis_status': 'queued',
    });
    final queueFailed = TranscriptionCorrectionResult.fromJson({
      'segment_id': 'segment-1',
      'transcription_id': 'transcription-1',
      'text': 'Corrected memory',
      'speaker_label': 'other',
      'updated_at': '2026-10-02T12:00:00Z',
      'reanalysis_status': 'queue_failed',
    });
    final unchanged = TranscriptionCorrectionResult.fromJson({
      'segment_id': 'segment-1',
      'transcription_id': 'transcription-1',
      'text': 'Corrected memory',
      'speaker_label': 'unknown',
      'updated_at': '2026-10-02T12:00:00Z',
      'reanalysis_status': 'unchanged',
    });

    expect(queued.queued, isTrue);
    expect(queueFailed.queueFailed, isTrue);
    expect(unchanged.unchanged, isTrue);
    expect(queued.updatedAt.isUtc, isTrue);
  });

  test('rejects malformed correction results', () {
    expect(
      () => TranscriptionCorrectionResult.fromJson({
        'segment_id': 'segment-1',
        'transcription_id': 42,
        'text': 'Corrected memory',
        'speaker_label': 'self',
        'updated_at': '2026-10-02T12:00:00Z',
        'reanalysis_status': 'queued',
      }),
      throwsA(isA<TypeError>()),
    );
  });
}
