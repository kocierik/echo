import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/photo.dart';
import 'package:echo_app/screens/conversation_detail_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/conversation_card.dart';
import 'package:echo_app/widgets/memory_entity_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

final class _PhotoMemoryApi extends FakeMemoryApi implements PhotoApi {
  _PhotoMemoryApi({super.details});

  @override
  Future<PhotoImageSource> photoImage(String id) async => PhotoImageSource(
        url: Uri.parse('https://echo.test/api/photos/$id/image'),
        headers: const {},
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

ConversationDetail _detail() => ConversationDetail(
      card: card('c1', startedAt: DateTime(2026, 10, 14, 12, 30)),
      lines: [
        TranscriptLine(
          segmentId: 's1',
          recordedAt: DateTime(2026, 10, 14, 12, 30),
          status: 'completed',
          text: '[You] Guarda la lavagna.',
          speaker: 'self',
        ),
        TranscriptLine(
          segmentId: 's2',
          recordedAt: DateTime(2026, 10, 14, 12, 35),
          status: 'completed',
          text: '[You] Ok, segnato.',
          speaker: 'self',
        ),
      ],
      entities: const [
        MemoryEntity(
          id: 'e1',
          type: 'event',
          name: 'Riunione Q4',
          metadata: {'event_date': '2026-10-16', 'photo_id': 'ph1'},
        ),
      ],
      photos: [
        ConversationPhoto(
          id: 'ph1',
          takenAt: DateTime(2026, 10, 14, 12, 31),
          answer: 'Una lavagna con la riunione Q4.',
        ),
      ],
    );

void main() {
  test('photos and their count are read from the API', () {
    final detail = ConversationDetail.fromJson({
      'id': 'c1',
      'started_at': '2026-10-14T12:30:00Z',
      'photo_count': 2,
      'transcriptions': const [],
      'entities': const [],
      'photos': [
        {
          'id': 'ph1',
          'taken_at': '2026-10-14T12:31:00Z',
          'answer': 'Una lavagna.'
        },
      ],
    });
    expect(detail.card.photoCount, 2);
    expect(detail.photos.single.answer, 'Una lavagna.');
  });

  testWidgets('the summary has the photos, the transcript has them in place',
      (tester) async {
    final api = _PhotoMemoryApi(details: {'c1': _detail()});
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ConversationDetailScreen(conversationId: 'c1', api: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Photos'), findsOneWidget);
    expect(find.byKey(const Key('conversation-photo-ph1')), findsOneWidget);

    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    final photo =
        tester.getTopLeft(find.byKey(const Key('conversation-photo-ph1'))).dy;
    final before = tester.getTopLeft(find.byKey(const Key('line-s1'))).dy;
    final after = tester.getTopLeft(find.byKey(const Key('line-s2'))).dy;
    expect(before < photo && photo < after, isTrue);
  });

  testWidgets('no photos without an api that serves them', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ConversationDetailScreen(
        conversationId: 'c1',
        api: FakeMemoryApi(details: {'c1': _detail()}),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conversation-photo-ph1')), findsNothing);
  });

  testWidgets('the conversation card counts photos', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: ConversationCardTile(
          conversation: ConversationCard(
            id: 'c1',
            startedAt: DateTime(2026, 10, 14, 12, 30),
            title: 'Riunione',
            photoCount: 2,
          ),
          onTap: () {},
        ),
      ),
    ));
    expect(find.text('2 photos'), findsOneWidget);
  });

  testWidgets('an entity from a photo says so', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: MemoryEntityRow(
          entity: MemoryEntity(
            id: 'e1',
            type: 'task',
            name: 'Inviare il preventivo',
            metadata: {'photo_id': 'ph1'},
          ),
        ),
      ),
    ));
    expect(find.text('From a photo'), findsOneWidget);
  });
}
