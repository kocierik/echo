import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/screens/memories_screen.dart';
import 'package:echo_app/services/memory/memories_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  final now = DateTime(2026, 10, 14, 18);

  Future<void> pump(
    WidgetTester tester,
    FakeMemoryApi api, {
    MemoriesController? controller,
    List<String>? opened,
    List<String>? openedPeople,
    ThemeData? theme,
    Size size = const Size(375, 812),
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: MemoriesScreen(
            api: api,
            controller: controller,
            clock: () => now,
            openConversation: (context, id) async => opened?.add(id),
            openPerson: (context, id) async => openedPeople?.add(id),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('lists conversations by day with live, people and tasks', (tester) async {
    final opened = <String>[];
    final api = FakeMemoryApi(conversations: [
      card('live', startedAt: DateTime(2026, 10, 14, 17, 50), title: null, emoji: null,
          isOpen: true, people: const [], taskCount: 0),
      card('lunch', startedAt: DateTime(2026, 10, 14, 12, 30),
          people: const ['Ada', 'Marco'], taskCount: 2),
      card('old', startedAt: DateTime(2026, 10, 13, 9), title: 'Standup',
          summary: null, taskCount: 0, people: const []),
    ]);

    await pump(tester, api, opened: opened);

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Conversation in progress'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Lunch with Ada'), findsOneWidget);
    expect(find.text('12:30'), findsOneWidget);
    expect(find.text('Ada, Marco'), findsOneWidget);
    expect(find.text('2 tasks'), findsOneWidget);
    expect(find.text('12 min'), findsWidgets);
    expect(find.text('Standup'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Today')).dy,
      lessThan(tester.getTopLeft(find.text('Yesterday')).dy),
    );

    await tester.tap(find.text('Lunch with Ada'));
    await tester.pumpAndSettle();
    expect(opened, ['lunch']);
  });

  testWidgets('the weekly and daily summaries sit above the days', (tester) async {
    final api = FakeTodayApi(
      conversations: [card('lunch', startedAt: DateTime(2026, 10, 14, 12, 30))],
      digest: DailySummary(date: DateTime(2026, 10, 13), summary: 'Met Ada about Atlas.'),
      week: WeeklySummary(
        weekStart: DateTime(2026, 10, 5),
        summary: 'A week of planning the demo.',
        highlights: const ['Demo moved to Friday'],
        people: const ['Marco', 'Ada'],
      ),
    );
    await pump(tester, api);

    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Met Ada about Atlas.'), findsOneWidget);
    expect(find.text('Last week'), findsOneWidget);
    expect(find.text('With Marco, Ada'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Met Ada about Atlas.')).dy,
      lessThan(tester.getTopLeft(find.text('Today')).dy),
    );

    expect(find.text('• Demo moved to Friday'), findsNothing);
    await tester.tap(find.byKey(const Key('weekly-summary-content')));
    await tester.pumpAndSettle();
    expect(find.text('• Demo moved to Friday'), findsOneWidget);
  });

  testWidgets('no summaries before the first ones', (tester) async {
    await pump(tester, FakeTodayApi(
      conversations: [card('lunch', startedAt: DateTime(2026, 10, 14, 12, 30))],
    ));
    expect(find.byKey(const Key('weekly-summary')), findsNothing);
    expect(find.byKey(const Key('daily-summary')), findsNothing);
  });

  testWidgets('empty memory explains when conversations appear', (tester) async {
    await pump(tester, FakeMemoryApi());

    expect(find.text('No memories yet'), findsOneWidget);
  });

  testWidgets('a failed first load offers a retry that recovers', (tester) async {
    final api = FakeMemoryApi()..listError = serverError('Offline');
    await pump(tester, api);
    expect(find.text('Could not load your memories'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);

    api
      ..listError = null
      ..conversations = [card('c1', startedAt: DateTime(2026, 10, 14, 9))];
    await tester.tap(find.byKey(const Key('memories-retry')));
    await tester.pumpAndSettle();

    expect(find.text('Lunch with Ada'), findsOneWidget);
  });

  testWidgets('search shows conversations and mentions, or no results', (tester) async {
    final opened = <String>[];
    late void Function() runSearch;
    final api = FakeMemoryApi(conversations: [card('c1', startedAt: DateTime(2026, 10, 14, 9))])
      ..searchResults = MemorySearchResults(
        conversations: [card('hit', startedAt: DateTime(2026, 10, 12, 9), title: 'Atlas kickoff')],
        entities: const [
          MemoryEntity(
            id: 'e1',
            type: 'idea',
            name: 'Atlas dashboard',
            sourceText: '[Tu] Facciamo una dashboard per Atlas.',
            conversationId: 'hit',
          ),
        ],
      );
    final controller = MemoriesController(
      api: api,
      debounceScheduler: (delay, callback) {
        runSearch = callback;
        return () {};
      },
    );
    addTearDown(controller.dispose);
    await pump(tester, api, controller: controller, opened: opened);

    await tester.enterText(find.byKey(const Key('memories-search')), 'atlas');
    await tester.pump();
    expect(find.byKey(const Key('search-loading')), findsOneWidget);
    runSearch();
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SectionHeader, 'Conversations'), findsOneWidget);
    expect(find.text('Atlas kickoff'), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Mentions'), findsOneWidget);
    expect(find.text('Atlas dashboard'), findsOneWidget);
    expect(find.text('“Facciamo una dashboard per Atlas.”'), findsOneWidget);
    await tester.tap(find.text('Atlas dashboard'));
    await tester.pumpAndSettle();
    expect(opened, ['hit']);

    api.searchResults = const MemorySearchResults(conversations: [], entities: []);
    await tester.enterText(find.byKey(const Key('memories-search')), 'zzz');
    await tester.pump();
    runSearch();
    await tester.pumpAndSettle();
    expect(find.text('No results'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memories-search-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Lunch with Ada'), findsOneWidget);
  });

  testWidgets('People shows the four seen last; All lists and filters everyone',
      (tester) async {
    final openedPeople = <String>[];
    final api = FakeMemoryApi(conversations: [card('c1', startedAt: DateTime(2026, 10, 14, 9))])
      ..people = [
        PersonSummary(
          id: 'p1',
          name: 'Marco Rossi',
          role: 'designer',
          lastSeen: DateTime(2026, 10, 14, 9),
          conversationCount: 3,
          openTaskCount: 2,
        ),
        const PersonSummary(id: 'p2', name: 'Ada', conversationCount: 1),
        for (var i = 3; i <= 6; i++)
          PersonSummary(id: 'p$i', name: 'Person $i', lastSeen: DateTime(2026, 10, i)),
      ];
    await pump(tester, api, openedPeople: openedPeople);

    // On the panel: first names, the most recently seen first
    Finder onPanel(String text) =>
        find.descendant(of: find.byKey(const Key('people-panel')), matching: find.text(text));
    expect(onPanel('Marco'), findsOneWidget);
    expect(onPanel('Person'), findsNWidgets(3));
    expect(onPanel('Ada'), findsNothing);
    await tester.tap(find.byKey(const Key('person-p1')));
    await tester.pumpAndSettle();
    expect(openedPeople, ['p1']);

    await tester.tap(find.text('All 6'));
    await tester.pumpAndSettle();
    expect(find.text('Marco Rossi'), findsOneWidget);
    expect(find.text('designer · Seen today'), findsOneWidget);
    expect(find.text('3 conversations · 2 open tasks'), findsOneWidget);
    expect(find.text('1 conversation'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('people-filter')), 'ad');
    await tester.pumpAndSettle();
    expect(find.text('Marco Rossi'), findsNothing);
    expect(find.text('Ada'), findsOneWidget);
    expect(api.calls.any((c) => c.startsWith('search')), isFalse);

    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    expect(openedPeople, ['p1', 'p2']);
  });

  testWidgets('no People panel without people, or when they fail to load',
      (tester) async {
    final api = FakeMemoryApi(conversations: [card('c1', startedAt: DateTime(2026, 10, 14, 9))])
      ..peopleError = serverError('Offline');
    await pump(tester, api);
    expect(find.byKey(const Key('people-panel')), findsNothing);
    expect(find.text('Lunch with Ada'), findsOneWidget);
  });

  testWidgets('fits 320 wide at 1.3 text scale in light and dark', (tester) async {
    final api = FakeMemoryApi(conversations: [
      card('long', startedAt: DateTime(2026, 10, 14, 9),
          title: 'A very long conversation title that keeps going and going',
          summary: 'A summary long enough to need two lines and then some more words.',
          people: const ['Alessandro', 'Margherita', 'Bartolomeo'],
          taskCount: 12, duration: const Duration(hours: 69, minutes: 50)),
      card('live', startedAt: DateTime(2026, 10, 14, 17), isOpen: true),
    ])
      ..people = [
        const PersonSummary(id: 'p1', name: 'Bartolomeo Alessandrini'),
        const PersonSummary(id: 'p2', name: 'Margherita'),
      ];
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await pump(tester, api, theme: theme, size: const Size(320, 640), textScale: 1.3);
      expect(tester.takeException(), isNull);
    }
  });
}
