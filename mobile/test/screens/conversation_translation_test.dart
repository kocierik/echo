import 'package:echo_app/models/memory.dart';
import 'package:echo_app/screens/conversation_detail_screen.dart';
import 'package:echo_app/services/api/memory_api.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

final class _TranslatingApi extends FakeMemoryApi implements TranslateApi {
  _TranslatingApi({super.details});

  int asked = 0;
  bool failing = false;

  @override
  Future<TranscriptTranslation> translateConversation(String id) async {
    asked++;
    if (failing) throw Exception('offline');
    return const TranscriptTranslation(
      language: 'it',
      lines: {'s2': 'Ci vediamo domani alle nove.'},
    );
  }
}

void main() {
  ConversationDetail detail({String foreign = 'en'}) => ConversationDetail(
        card: card('c1', startedAt: DateTime(2026, 10, 27, 10)),
        lines: [
          TranscriptLine(
            segmentId: 's1',
            recordedAt: DateTime(2026, 10, 27, 10),
            status: 'completed',
            text: '[Self] Ciao Mark.',
            speaker: 'self',
            language: 'it',
          ),
          TranscriptLine(
            segmentId: 's2',
            recordedAt: DateTime(2026, 10, 27, 10, 1),
            status: 'completed',
            text: '[Others] See you tomorrow at nine.',
            speaker: 'other',
            language: foreign,
          ),
        ],
        entities: const [],
      );

  Future<void> pump(WidgetTester tester, FakeMemoryApi api) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ConversationDetailScreen(
        conversationId: 'c1',
        api: api,
        spokenLanguage: () async => 'it',
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
  }

  testWidgets('a line in another language is tagged; Translate shows it in yours',
      (tester) async {
    final api = _TranslatingApi(details: {'c1': detail()});
    await pump(tester, api);

    expect(find.byKey(const Key('lang-s2')), findsOneWidget);
    expect(find.text('EN'), findsOneWidget);
    expect(find.byKey(const Key('lang-s1')), findsNothing);
    expect(find.text('Translate to Italiano'), findsOneWidget);

    await tester.tap(find.byKey(const Key('transcript-translate')));
    await tester.pumpAndSettle();

    expect(api.asked, 1);
    expect(find.text('Ci vediamo domani alle nove.'), findsOneWidget);
    // The original stays
    expect(find.text('See you tomorrow at nine.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Ci vediamo domani alle nove.')).dy,
      greaterThan(tester.getTopLeft(find.text('See you tomorrow at nine.')).dy),
    );

    await tester.tap(find.text('Hide translation'));
    await tester.pumpAndSettle();
    expect(find.text('Ci vediamo domani alle nove.'), findsNothing);

    // Shown again without asking again
    await tester.tap(find.text('Translate to Italiano'));
    await tester.pumpAndSettle();
    expect(find.text('Ci vediamo domani alle nove.'), findsOneWidget);
    expect(api.asked, 1);
  });

  testWidgets('a conversation all in your language offers no translation', (tester) async {
    await pump(tester, _TranslatingApi(details: {'c1': detail(foreign: 'it')}));

    expect(find.byKey(const Key('transcript-translate')), findsNothing);
    expect(find.text('EN'), findsNothing);
  });

  testWidgets('a failing translation says so', (tester) async {
    final api = _TranslatingApi(details: {'c1': detail()})..failing = true;
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('transcript-translate')));
    await tester.pumpAndSettle();

    expect(find.text('Could not translate. Try again.'), findsOneWidget);
    expect(find.text('Translate to Italiano'), findsOneWidget);
  });

  test('a line reads its language', () {
    final line = TranscriptLine.fromJson(const {
      'segment_id': 's1',
      'text': 'Hello',
      'status': 'completed',
      'recorded_at': '2026-10-27T10:00:00Z',
      'language': 'en',
    });
    expect(line.language, 'en');
  });
}
