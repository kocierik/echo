import 'package:echo_app/services/api_service.dart';
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
}
