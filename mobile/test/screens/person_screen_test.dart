import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/screens/conversation_detail_screen.dart';
import 'package:echo_app/screens/person_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  final now = DateTime(2026, 10, 14, 18);

  PersonDetail marco({
    bool linked = true,
    List<PersonFact> facts = const [],
    List<PersonFact> earlierFacts = const [],
  }) => PersonDetail(
        person: PersonSummary(
          id: 'p1',
          name: 'Marco Rossi',
          role: 'designer',
          about: 'Leads the Atlas design.',
          lastSeen: DateTime(2026, 10, 13, 9),
          conversationCount: 2,
          openTaskCount: 1,
        ),
        conversations: linked
            ? [card('c1', startedAt: DateTime(2026, 10, 13, 9), title: 'Atlas design review')]
            : const [],
        tasks: linked
            ? [task('t1', 'Send Marco the specs', due: DateTime(2026, 10, 15), source: '[Tu] Mando le specifiche a Marco.')]
            : const [],
        events: linked
            ? const [
                MemoryEntity(
                  id: 'e1',
                  type: 'event',
                  name: 'Dinner with Marco',
                  metadata: {'event_date': '2026-10-17', 'event_time': '20:00'},
                ),
              ]
            : const [],
        facts: facts,
        earlierFacts: earlierFacts,
      );

  PersonFact fact(
    String id,
    String text, {
    String category = 'work',
    String quote = '[Marco] Lavoro al progetto Atlas.',
    String? conversationId = 'c1',
    int day = 13,
  }) => PersonFact.fromJson({
        'id': id,
        'text': text,
        'category': category,
        'quote': quote,
        'conversation_id': conversationId,
        'created_at': DateTime(2026, 10, day, 9).toIso8601String(),
      });

  Future<List<String>> pump(
    WidgetTester tester,
    FakeMemoryApi api, {
    double height = 1000,
  }) async {
    final asked = <String>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(375, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PersonScreen(
                personId: 'p1',
                api: api,
                onAsk: asked.add,
                clock: () => now,
              ),
            )),
            child: const Text('tabs'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('tabs'));
    await tester.pumpAndSettle();
    return asked;
  }

  testWidgets('shows who they are and everything linked to them', (tester) async {
    await pump(tester, FakeMemoryApi()..personDetails = {'p1': marco()});

    expect(find.text('MR'), findsOneWidget);
    expect(find.text('Marco Rossi'), findsOneWidget);
    expect(find.text('designer · Seen yesterday'), findsOneWidget);
    expect(find.text('Leads the Atlas design.'), findsOneWidget);
    expect(find.text('Send Marco the specs'), findsOneWidget);
    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('Dinner with Marco'), findsOneWidget);
    expect(find.text('Sat, Oct 17 at 20:00'), findsOneWidget);
    expect(find.text('Atlas design review'), findsOneWidget);
  });

  testWidgets('Ask goes back to the tabs and asks about them', (tester) async {
    final asked = await pump(tester, FakeMemoryApi()..personDetails = {'p1': marco()});

    await tester.tap(find.byKey(const Key('person-ask')));
    await tester.pumpAndSettle();

    expect(asked.single, contains('Marco Rossi'));
    expect(find.text('tabs'), findsOneWidget);
  });

  testWidgets('a task can be completed from the person', (tester) async {
    final api = FakeMemoryApi()..personDetails = {'p1': marco()};
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('task-toggle-t1')));
    await tester.pumpAndSettle();

    expect(api.calls, contains('done t1 true'));
  });

  testWidgets('a person Echo got wrong is deleted, after a confirmation', (tester) async {
    final api = FakeMemoryApi()..personDetails = {'p1': marco()};
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('person-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete Marco Rossi?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.calls, isNot(contains('delete entity p1')));

    await tester.tap(find.byKey(const Key('person-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(api.calls, contains('delete entity p1'));
    // Back where the person was opened
    expect(find.text('tabs'), findsOneWidget);
  });

  testWidgets('a failed delete stays on the person and says so', (tester) async {
    final api = FakeMemoryApi()..personDetails = {'p1': marco()};
    await pump(tester, api);
    api.taskError = serverError('Offline');

    await tester.tap(find.byKey(const Key('person-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Marco Rossi'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('nothing linked yet, and a retry after a failure', (tester) async {
    final api = FakeMemoryApi()..peopleError = serverError('Offline');
    await pump(tester, api);
    expect(find.text('Could not load this person'), findsOneWidget);

    api
      ..peopleError = null
      ..personDetails = {'p1': marco(linked: false)};
    await tester.tap(find.byKey(const Key('person-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing else is linked to Marco Rossi yet.'), findsOneWidget);
  });

  testWidgets('what Echo knows, by category, newest first', (tester) async {
    await pump(tester, FakeMemoryApi()..personDetails = {
      'p1': marco(linked: false, facts: [
        fact('h', 'Lives in Milan', category: 'home'),
        fact('old', 'Designed Atlas', day: 11),
        fact('o', 'Speaks Italian', category: 'other'),
        fact('p', 'Will travel', category: 'plans'),
        fact('i', 'Likes cycling', category: 'interests'),
        fact('f', 'Has a sister', category: 'family'),
        fact('new', 'Leads Atlas', day: 14),
      ]),
    }, height: 2400);

    expect(find.text('What Echo knows'), findsOneWidget);
    const headings = ['Work', 'Family', 'Home', 'Interests', 'Plans', 'Other'];
    for (var index = 0; index < headings.length; index++) {
      expect(find.text(headings[index]), findsOneWidget);
      if (index > 0) {
        expect(tester.getTopLeft(find.text(headings[index])).dy,
            greaterThan(tester.getTopLeft(find.text(headings[index - 1])).dy));
      }
    }
    final work = find.ancestor(
      of: find.text('Work'),
      matching: find.byType(PanelSection),
    );
    expect(find.descendant(of: work, matching: find.text('Leads Atlas')), findsOneWidget);
    expect(find.descendant(of: work, matching: find.text('Designed Atlas')), findsOneWidget);
    expect(tester.getTopLeft(find.text('Leads Atlas')).dy,
        lessThan(tester.getTopLeft(find.text('Designed Atlas')).dy));
    final home = find.ancestor(
      of: find.text('Home'),
      matching: find.byType(PanelSection),
    );
    expect(find.descendant(of: home, matching: find.text('Lives in Milan')), findsOneWidget);
  });

  testWidgets('a fact shows its evidence', (tester) async {
    const quote = '  [Marco] «Lavoro ad Atlas», ha detto.  ';
    await pump(tester, FakeMemoryApi()..personDetails = {
      'p1': marco(linked: false, facts: [fact('f1', 'Leads Atlas', quote: quote)]),
    });

    final row = find.byKey(const Key('person-fact-f1'));
    expect(find.descendant(of: row, matching: find.text(quote)), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Oct 13, 2026')), findsOneWidget);
    expect(tester.getTopLeft(find.text(quote)).dy,
        greaterThan(tester.getTopLeft(find.text('Leads Atlas')).dy));
    expect(tester.getTopLeft(find.text('Oct 13, 2026')).dy,
        greaterThan(tester.getTopLeft(find.text(quote)).dy));
  });

  testWidgets('a fact opens its conversation', (tester) async {
    final api = FakeMemoryApi()..personDetails = {
      'p1': marco(linked: false, facts: [fact('f1', 'Leads Atlas')]),
    };
    await pump(tester, api);

    await tester.tap(find.text('Leads Atlas'));
    await tester.pumpAndSettle();

    expect(find.byType(ConversationDetailScreen), findsOneWidget);
    expect(tester.widget<ConversationDetailScreen>(
      find.byType(ConversationDetailScreen),
    ).conversationId, 'c1');
    expect(api.calls, contains('detail c1'));
  });

  testWidgets('a deleted conversation retains evidence without navigation', (tester) async {
    const quote = '[Marco] Vivo a Milano.';
    final api = FakeMemoryApi()..personDetails = {
      'p1': marco(linked: false, facts: [
        fact('f1', 'Lives in Milan', quote: quote, conversationId: null),
      ]),
    };
    await pump(tester, api);

    expect(find.text(quote), findsOneWidget);
    expect(find.text('Oct 13, 2026'), findsOneWidget);
    expect(tester.widget<InkWell>(find.byKey(const Key('person-fact-f1'))).onTap, isNull);
    await tester.tap(find.text('Lives in Milan'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationDetailScreen), findsNothing);
    expect(api.calls.where((call) => call.startsWith('detail ')), isEmpty);
  });

  testWidgets('Not true removes a fact and reloads the person', (tester) async {
    final api = FakeMemoryApi()..personDetails = {
      'p1': marco(linked: false, facts: [fact('f1', 'Leads Atlas')]),
    };
    await pump(tester, api);

    await tester.longPress(find.text('Leads Atlas'));
    await tester.pumpAndSettle();
    expect(api.calls, isNot(contains('delete person fact p1 f1')));
    await tester.tap(find.text('Not true'));
    await tester.pumpAndSettle();

    expect(api.calls, contains('delete person fact p1 f1'));
    expect(api.calls.where((call) => call == 'person p1'), hasLength(2));
    expect(find.text('Leads Atlas'), findsNothing);
    expect(find.text('What Echo knows'), findsNothing);
  });

  testWidgets('Before lists superseded facts, collapsed', (tester) async {
    const quote = '[Marco] Lavoro a Roma.';
    await pump(tester, FakeMemoryApi()..personDetails = {
      'p1': marco(linked: false, earlierFacts: [
        fact('old', 'Worked in Rome', quote: quote, conversationId: null, day: 10),
      ]),
    });

    expect(find.text('What Echo knows'), findsOneWidget);
    expect(find.text('Before'), findsOneWidget);
    expect(find.text('Worked in Rome'), findsNothing);
    expect(find.text(quote), findsNothing);
    await tester.tap(find.text('Before'));
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text('Worked in Rome'));
    expect(text.style?.decoration, TextDecoration.lineThrough);
    expect(find.text(quote), findsOneWidget);
    expect(find.text('Oct 10, 2026'), findsOneWidget);
    await tester.tap(find.text('Before'));
    await tester.pumpAndSettle();
    expect(find.text('Worked in Rome'), findsNothing);
  });

  testWidgets('no facts, no panel', (tester) async {
    await pump(tester, FakeMemoryApi()..personDetails = {'p1': marco()});

    expect(find.text('What Echo knows'), findsNothing);
    expect(find.text('Before'), findsNothing);
    expect(find.text('Work'), findsNothing);
    expect(find.text('Atlas design review'), findsOneWidget);
  });

  testWidgets('delete failure is visible without reloading or hiding the fact', (tester) async {
    final api = FakeMemoryApi()..personDetails = {
      'p1': marco(linked: false, facts: [fact('f1', 'Leads Atlas')]),
    };
    await pump(tester, api);
    api.taskError = serverError('The server could not reject this fact.');

    await tester.longPress(find.text('Leads Atlas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not true'));
    await tester.pumpAndSettle();

    expect(api.calls, contains('delete person fact p1 f1'));
    expect(api.calls.where((call) => call == 'person p1'), hasLength(1));
    expect(find.text('Leads Atlas'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('The server could not reject this fact.'), findsOneWidget);
  });
}
