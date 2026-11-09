import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/place.dart';
import 'package:echo_app/screens/conversation_detail_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  final now = DateTime(2026, 10, 14, 18);

  ConversationDetail detail({
    String? summary = 'Ada proposes Atlas.',
    bool isOpen = false,
    ConversationPlace? place,
    List<TranscriptLine>? lines,
  }) {
    return ConversationDetail(
      card: card(
        'c1',
        startedAt: DateTime(2026, 10, 14, 12, 30),
        summary: summary,
        isOpen: isOpen,
        duration: const Duration(minutes: 45),
        place: place,
      ),
      lines: lines ?? [
        TranscriptLine(
          segmentId: 's1',
          recordedAt: DateTime(2026, 10, 14, 12, 30),
          status: 'completed',
          text: '[Tu] Domani chiamo Ada per Atlas.',
          speaker: 'self',
        ),
        TranscriptLine(
          segmentId: 's2',
          recordedAt: DateTime(2026, 10, 14, 12, 31),
          status: 'pending',
        ),
      ],
      entities: const [
        MemoryEntity(id: 'p1', type: 'person', name: 'Ada'),
        MemoryEntity(
          id: 't1',
          type: 'task',
          name: 'Chiamare Ada',
          metadata: {'due_date': '2026-10-15'},
          sourceText: '[Tu] Domani chiamo Ada per Atlas.',
          conversationId: 'c1',
        ),
        MemoryEntity(
          id: 'e1',
          type: 'event',
          name: 'Dentista',
          metadata: {'event_date': '2026-10-16', 'event_time': '15:00'},
        ),
        MemoryEntity(id: 'i1', type: 'idea', name: 'Atlas dashboard', content: 'For the team'),
      ],
    );
  }

  Future<void> pump(
    WidgetTester tester,
    FakeMemoryApi api, {
    List<String>? asked,
    Size size = const Size(375, 900),
    double textScale = 1,
    ThemeData? theme,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ConversationDetailScreen(
                    conversationId: 'c1',
                    api: api,
                    onAsk: asked?.add,
                    clock: () => now,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('summary shows the header, tasks with sources, events and ideas', (tester) async {
    final api = FakeMemoryApi(details: {'c1': detail()});
    await pump(tester, api);

    expect(find.text('Lunch with Ada'), findsOneWidget);
    expect(find.text('Today · 12:30–13:15 · 45 min'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Ada'), findsOneWidget);
    expect(find.text('Ada proposes Atlas.'), findsOneWidget);
    expect(find.text('Chiamare Ada'), findsOneWidget);
    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('“Domani chiamo Ada per Atlas.”'), findsOneWidget);
    expect(find.text('Dentista'), findsOneWidget);
    expect(find.text('Fri, Oct 16 at 15:00'), findsOneWidget);
    expect(find.text('Ideas & notes'), findsOneWidget);
    expect(find.text('For the team'), findsOneWidget);
  });

  testWidgets('the place it happened, with its address', (tester) async {
    const place = ConversationPlace(
      visitId: 'v1',
      name: 'Trattoria da Mario',
      address: 'Via Roma 12, Milano',
    );
    await pump(tester, FakeMemoryApi(details: {'c1': detail(place: place)}));

    expect(find.text('Trattoria da Mario · Via Roma 12, Milano'), findsOneWidget);
  });

  testWidgets('no place without Places visited', (tester) async {
    await pump(tester, FakeMemoryApi(details: {'c1': detail()}));

    expect(find.byKey(const Key('conversation-place')), findsNothing);
  });

  testWidgets('Ask about this conversation goes back and asks', (tester) async {
    final asked = <String>[];
    await pump(tester, FakeMemoryApi(details: {'c1': detail()}), asked: asked);

    await tester.tap(find.byKey(const Key('conversation-ask')));
    await tester.pumpAndSettle();

    expect(asked.single, contains('"Lunch with Ada"'));
    expect(asked.single, contains('Today, 12:30'));
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('an event goes to the calendar through Ask', (tester) async {
    final asked = <String>[];
    await pump(tester, FakeMemoryApi(details: {'c1': detail()}), asked: asked);

    await tester.tap(find.byKey(const Key('entity-calendar-e1')));
    await tester.pumpAndSettle();

    expect(asked, ['Add "Dentista" to my Google Calendar on 2026-10-16 at 15:00.']);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('without Ask there is no calendar button', (tester) async {
    await pump(tester, FakeMemoryApi(details: {'c1': detail()}));

    expect(find.byKey(const Key('entity-calendar-e1')), findsNothing);
  });

  testWidgets('a task is completed in place, and a failure undoes it', (tester) async {
    final api = FakeMemoryApi(details: {'c1': detail()});
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('task-toggle-t1')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('done t1 true'));
    expect(find.byTooltip('Mark "Chiamare Ada" as not done'), findsOneWidget);

    api.taskError = serverError('No network');
    await tester.tap(find.byKey(const Key('task-toggle-t1')));
    await tester.pumpAndSettle();
    expect(find.text('No network'), findsOneWidget);
    expect(find.byTooltip('Mark "Chiamare Ada" as not done'), findsOneWidget);
  });

  testWidgets('Not a task removes it from the conversation', (tester) async {
    final api = FakeMemoryApi(details: {'c1': detail()});
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('task-menu-t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-dismiss-t1')));
    await tester.pumpAndSettle();

    expect(api.calls, contains('delete entity t1'));
    expect(find.text('Chiamare Ada'), findsNothing);
  });

  testWidgets('the transcript lists lines with speakers and pending ones', (tester) async {
    final api = FakeMemoryApi(details: {'c1': detail()});
    await pump(tester, api);

    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();

    expect(find.text('Domani chiamo Ada per Atlas.'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Transcribing…'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);
  });

  testWidgets('a segment where several spoke shows who said what', (tester) async {
    final api = FakeMemoryApi(details: {
      'c1': detail(lines: [
        TranscriptLine(
          segmentId: 's1',
          recordedAt: DateTime(2026, 10, 14, 12, 30),
          status: 'completed',
          text: '[You] Ciao, come stai? Bene, grazie.',
          speaker: 'self',
          turns: const [
            Turn(speaker: 'self', text: 'Ciao, come stai?'),
            Turn(speaker: 'other', speakerName: 'Person 2', text: 'Bene, grazie.'),
          ],
        ),
      ]),
    });
    await pump(tester, api);

    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();

    expect(find.text('You'), findsOneWidget);
    expect(find.text('Ciao, come stai?'), findsOneWidget);
    expect(find.text('Person 2'), findsOneWidget);
    expect(find.text('Bene, grazie.'), findsOneWidget);
  });

  test('a line reads its turns from the server', () {
    final line = TranscriptLine.fromJson(const {
      'segment_id': 's1',
      'recorded_at': '2026-10-14T12:30:00Z',
      'status': 'completed',
      'text': '[You] Ciao. Bene.',
      'speaker_label': 'self',
      'turns': [
        {'speaker_label': 'self', 'speaker_name': 'You', 'text': 'Ciao.'},
        {'speaker_label': 'other', 'speaker_name': null, 'text': 'Bene.'},
      ],
    });

    expect(line.turns.map((t) => t.speakerLabel), ['You', 'Other']);
    expect(line.turns.last.text, 'Bene.');
  });

  testWidgets('a live conversation opens on its transcript; the summary comes later',
      (tester) async {
    final api = FakeMemoryApi(details: {'c1': detail(summary: null, isOpen: true)});
    await pump(tester, api);

    // What is being said first
    expect(find.text('Domani chiamo Ada per Atlas.'), findsOneWidget);
    expect(find.text('Live · still listening'), findsOneWidget);

    await tester.tap(find.text('Summary'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Echo is still listening'), findsOneWidget);
  });

  testWidgets('a live conversation follows what is said, without a refresh', (tester) async {
    final api = FakeMemoryApi(details: {'c1': detail(summary: null, isOpen: true)});
    await pump(tester, api);
    expect(find.text('Lo mando stasera.'), findsNothing);

    final live = detail(summary: null, isOpen: true);
    api.details['c1'] = ConversationDetail(
      card: live.card,
      lines: [
        ...live.lines,
        TranscriptLine(
          segmentId: 's3', recordedAt: DateTime(2026, 10, 14, 12, 32), status: 'completed',
          text: '[You] Lo mando stasera.', speaker: 'self',
        ),
      ],
      entities: live.entities,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('Lo mando stasera.'), findsOneWidget);
  });

  testWidgets('delete asks first, then deletes and closes', (tester) async {
    final api = FakeMemoryApi(details: {'c1': detail()});
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete conversation?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('conversation-delete-confirm')));
    await tester.pumpAndSettle();

    expect(api.calls, contains('delete conversation c1'));
    expect(find.text('open'), findsOneWidget); // back on the previous screen
  });

  testWidgets('a load failure offers a retry', (tester) async {
    final api = FakeMemoryApi()..detailError = serverError('Offline');
    await pump(tester, api);
    expect(find.text('Could not load this conversation'), findsOneWidget);

    api
      ..detailError = null
      ..details = {'c1': detail()};
    await tester.tap(find.byKey(const Key('conversation-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Lunch with Ada'), findsOneWidget);
  });

  testWidgets('fits 320 wide at 1.3 text scale in light and dark', (tester) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await tester.pumpWidget(const SizedBox());
      await pump(
        tester,
        FakeMemoryApi(details: {'c1': detail()}),
        asked: [],
        size: const Size(320, 640),
        textScale: 1.3,
        theme: theme,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}
