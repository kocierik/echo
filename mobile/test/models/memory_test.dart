import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/models/task_item.dart';
import 'package:echo_app/widgets/formatting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationCard', () {
    test('parses every list field', () {
      final card = ConversationCard.fromJson(const {
        'id': 'c1',
        'title': ' Lunch with Ada ',
        'summary': 'Atlas.',
        'emoji': '🍝',
        'started_at': '2026-10-14T09:30:00Z',
        'ended_at': '2026-10-14T10:15:00Z',
        'duration_s': 2700,
        'segment_count': 4,
        'analysis_status': 'completed',
        'is_open': false,
        'people': ['Ada', 'Marco'],
        'task_count': 2,
      });

      expect(card.title, 'Lunch with Ada');
      expect(card.emoji, '🍝');
      expect(card.duration, const Duration(minutes: 45));
      expect(card.people, ['Ada', 'Marco']);
      expect(card.taskCount, 2);
      expect(card.isProcessing, isFalse);
    });

    test('tolerates the older list shape and blank text', () {
      final card = ConversationCard.fromJson(const {
        'id': 'c1',
        'title': '   ',
        'summary': null,
        'started_at': '2026-10-14T09:30:00Z',
        'analysis_status': 'processing',
      });

      expect(card.title, isNull);
      expect(card.emoji, isNull);
      expect(card.people, isEmpty);
      expect(card.isOpen, isFalse);
      expect(card.isProcessing, isTrue);
    });

    test('an open conversation is live, not processing', () {
      final card = ConversationCard.fromJson(const {
        'id': 'c1',
        'started_at': '2026-10-14T09:30:00Z',
        'analysis_status': 'pending',
        'is_open': true,
      });

      expect(card.isOpen, isTrue);
      expect(card.isProcessing, isFalse);
    });
  });

  test('a detail keeps pending lines and drops nameless entities', () {
    final detail = ConversationDetail.fromJson(const {
      'id': 'c1',
      'started_at': '2026-10-14T09:30:00Z',
      'transcriptions': [
        {
          'segment_id': 's1',
          'text': '[Tu] Chiamo Ada.',
          'speaker_label': 'self',
          'status': 'completed',
          'recorded_at': '2026-10-14T09:30:00Z',
        },
        {
          'segment_id': 's2',
          'text': null,
          'speaker_label': null,
          'status': 'pending',
          'recorded_at': '2026-10-14T09:31:00Z',
        },
      ],
      'entities': [
        {
          'id': 't1',
          'entity_type': 'task',
          'name': 'Chiamare Ada',
          'metadata_': {'due_date': '2026-10-15'},
          'source_text': '[Tu] Chiamo Ada.',
        },
        {'id': 'x', 'entity_type': 'note', 'name': ' ', 'metadata_': {}},
      ],
    });

    expect(detail.lines.map((l) => l.isPending), [false, true]);
    expect(detail.entities.map((e) => e.id), ['t1']);
    final task = TaskItem.fromEntity(detail.ofType('task').single);
    expect(task.dueDate, DateTime(2026, 10, 15));
    expect(task.sourceText, '[Tu] Chiamo Ada.');
  });

  test('TaskItem keeps the whole metadata when toggling done', () {
    final task = TaskItem.fromJson(const {
      'id': 't1',
      'name': 'Call Ada',
      'metadata_': {'priority': 'high'},
      'created_at': '2026-10-14T09:30:00Z',
    });

    expect(task.done, isFalse);
    expect(task.metadataWithDone(true), {'priority': 'high', 'done': true});
    expect(task.copyWithDone(true).done, isTrue);
    expect(task.copyWithDone(true).metadata['priority'], 'high');
  });

  group('formatting', () {
    test('durations read naturally', () {
      expect(formatDuration(const Duration(seconds: 45)), '45 s');
      expect(formatDuration(const Duration(minutes: 12)), '12 min');
      expect(formatDuration(const Duration(hours: 1)), '1 h');
      expect(formatDuration(const Duration(hours: 1, minutes: 20)), '1 h 20 min');
      expect(formatDuration(const Duration(hours: 69, minutes: 50)), '2 d 21 h');
    });

    test('day labels are relative near today', () {
      final now = DateTime(2026, 10, 14, 18);
      expect(dayLabel(DateTime(2026, 10, 14, 8), now), 'Today');
      expect(dayLabel(DateTime(2026, 10, 13, 23), now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 10, 15), now), 'Tomorrow');
      expect(dayLabel(DateTime(2026, 10, 16), now), 'Fri, Oct 16');
      expect(dayLabel(DateTime(2026, 10, 12), now), 'Mon, Oct 12');
      expect(dayLabel(DateTime(2025, 12, 31), now), 'Wed, Dec 31 2025');
    });

    test('transcript prefixes and speakers', () {
      expect(cleanTranscript('[Tu] Ciao'), 'Ciao');
      expect(cleanTranscript('[Others] Hi'), 'Hi');
      expect(cleanTranscript('No prefix'), 'No prefix');
      expect(speakerName('self'), 'You');
      expect(speakerName('other'), 'Other');
      expect(speakerName(null), 'Unknown');
    });
  });

  group('people', () {
    test('initials and optional fields', () {
      final marco = PersonSummary.fromJson(const {
        'id': 'p1',
        'name': 'Marco Rossi',
        'role': ' designer ',
        'about': '',
        'last_seen': '2026-10-14T09:30:00Z',
        'conversation_count': 3,
        'open_task_count': 1,
      });
      expect(marco.initials, 'MR');
      expect(marco.role, 'designer');
      expect(marco.about, isNull);
      expect(marco.conversationCount, 3);
      expect(const PersonSummary(id: 'a', name: 'ada').initials, 'A');
      expect(const PersonSummary(id: 'x', name: '').initials, '?');
    });

    test('a person detail parses conversations, tasks and events', () {
      final detail = PersonDetail.fromJson(const {
        'id': 'p1',
        'name': 'Ada',
        'last_seen': null,
        'conversations': [
          {'id': 'c1', 'started_at': '2026-10-14T09:30:00Z', 'title': 'Lunch'},
        ],
        'tasks': [
          {
            'id': 't1',
            'name': 'Call Ada',
            'metadata_': {'due_date': '2026-10-15'},
            'source_text': '[Tu] Chiamo Ada.',
            'conversation_id': 'c1',
            'created_at': '2026-10-14T09:30:00Z',
          },
        ],
        'events': [
          {'id': 'e1', 'entity_type': 'event', 'name': 'Dinner with Ada', 'metadata_': {}},
        ],
      });
      expect(detail.person.lastSeen, isNull);
      expect(detail.conversations.single.title, 'Lunch');
      expect(detail.tasks.single.dueDate, DateTime(2026, 10, 15));
      expect(detail.events.single.name, 'Dinner with Ada');
    });
  });
}
