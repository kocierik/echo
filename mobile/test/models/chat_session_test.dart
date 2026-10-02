import 'package:echo_app/models/chat_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatSessionDetail.fromJson', () {
    test('preserves message order, nullable timestamps, and citations', () {
      final detail = ChatSessionDetail.fromJson({
        'id': 'session-1',
        'title': 'Planning',
        'messages': [
          {
            'role': 'user',
            'content': 'What did we decide?',
            'timestamp': '2026-10-01T09:30:00Z',
          },
          {
            'role': 'assistant',
            'content': 'Ship the smaller version first.',
            'timestamp': null,
            'citations': [
              {'chunk_id': 'chunk-1', 'label': 'Roadmap meeting'},
            ],
          },
        ],
        'created_at': '2026-10-01T09:30:00Z',
        'updated_at': '2026-10-01T09:31:00Z',
      });

      expect(detail.id, 'session-1');
      expect(detail.title, 'Planning');
      expect(
        detail.messages.map((message) => message.role),
        ['user', 'assistant'],
      );
      expect(
        detail.messages.first.timestamp,
        DateTime.parse('2026-10-01T09:30:00Z'),
      );
      expect(detail.messages.last.timestamp, isNull);
      expect(detail.messages.first.citations, isNull);
      expect(detail.messages.last.citations, [
        {'chunk_id': 'chunk-1', 'label': 'Roadmap meeting'},
      ]);
      expect(
        () => detail.messages.add(
          const ChatSessionMessage(
            role: 'user',
            content: 'Mutate history',
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('rejects roles other than user and assistant', () {
      expect(
        () => ChatSessionDetail.fromJson({
          'id': 'session-1',
          'title': null,
          'messages': [
            {'role': 'system', 'content': 'Hidden prompt', 'timestamp': null},
          ],
          'created_at': '2026-10-01T09:30:00Z',
          'updated_at': '2026-10-01T09:31:00Z',
        }),
        throwsFormatException,
      );
    });

    test('rejects malformed required and optional fields', () {
      final malformedMessages = <Map<String, dynamic>>[
        {'role': 'user', 'timestamp': null},
        {'role': 'assistant', 'content': 42, 'timestamp': null},
        {'role': 'user', 'content': 'Hello', 'timestamp': 42},
        {
          'role': 'assistant',
          'content': 'Hello',
          'timestamp': null,
          'citations': ['chunk-1'],
        },
      ];

      for (final message in malformedMessages) {
        expect(
          () => ChatSessionDetail.fromJson({
            'id': 'session-1',
            'title': null,
            'messages': [message],
            'created_at': '2026-10-01T09:30:00Z',
            'updated_at': '2026-10-01T09:31:00Z',
          }),
          throwsFormatException,
        );
      }
    });
  });

  test('ChatSessionSummary parses every backend field strictly', () {
    final summary = ChatSessionSummary.fromJson({
      'id': 'session-1',
      'title': null,
      'message_count': 2,
      'created_at': '2026-10-01T09:30:00Z',
      'updated_at': '2026-10-01T09:31:00Z',
    });

    expect(summary.id, 'session-1');
    expect(summary.title, isNull);
    expect(summary.messageCount, 2);
    expect(summary.createdAt, DateTime.parse('2026-10-01T09:30:00Z'));
    expect(summary.updatedAt, DateTime.parse('2026-10-01T09:31:00Z'));

    expect(
      () => ChatSessionSummary.fromJson({
        'id': 'session-1',
        'title': null,
        'message_count': '2',
        'created_at': '2026-10-01T09:30:00Z',
        'updated_at': '2026-10-01T09:31:00Z',
      }),
      throwsFormatException,
    );
  });
}