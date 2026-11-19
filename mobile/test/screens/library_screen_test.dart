import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/screens/conversation_detail_screen.dart';
import 'package:echo_app/screens/day_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/screens/library_screen.dart';
import 'package:echo_app/screens/memory_search_screen.dart';
import 'package:echo_app/screens/people_screen.dart';
import 'package:echo_app/services/library_counts.dart';
import 'package:echo_app/services/memory/memories_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

class _WeekApi extends FakeMemoryApi implements WeeklySummaryApi {
  @override
  Future<WeeklySummary?> getLatestWeeklySummary() async =>
      WeeklySummary(weekStart: DateTime(2026, 11, 9), summary: 'A busy week');
}

void Function(bool) _setActive = (_) {};

void main() {
  final now = DateTime(2026, 11, 17, 18);

  Future<MemoriesController> pumpLibrary(
    WidgetTester tester, {
    required LibraryCounts counts,
    TextScaler textScaler = TextScaler.noScaling,
    FakeMemoryApi? api,
    ValueListenable<bool>? placesOn,
    int loads = 0,
    void Function()? onLoad,
    DateTime? at,
    bool active = true,
    MemoriesController? controller,
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = api ?? FakeMemoryApi();
    final memories = controller ?? MemoriesController(api: fake);
    await memories.initialize();
    addTearDown(memories.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: StatefulBuilder(builder: (context, set) {
        _setActive = (v) => set(() => active = v);
        return LibraryScreen(
          active: active,
          loadCounts: () async {
            onLoad?.call();
            return counts;
          },
          memories: memories,
          api: fake,
          placesOn: placesOn,
          clock: () => at ?? now,
        );
      }),
    ));
    await tester.pumpAndSettle();
    return memories;
  }

  testWidgets('the tiles show their counts, and a dash for an unknown one',
      (tester) async {
    await pumpLibrary(
      tester,
      counts: const LibraryCounts(
          people: 14,
          faces: ['M', 'G'],
          openTasks: 3,
          visitsThisWeek: 8,
          documents: 3),
    );
    expect(find.text('14 saved'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('3 open'), findsOneWidget);
    expect(find.text('8 this week'), findsOneWidget);
    expect(find.text('People and topics'), findsOneWidget);
  });

  testWidgets('places off says Off', (tester) async {
    await pumpLibrary(tester,
        counts: const LibraryCounts(visitsThisWeek: null),
        placesOn: ValueNotifier(false));
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('People opens the people page, inside Library', (tester) async {
    await pumpLibrary(tester,
        counts: const LibraryCounts(people: 1, faces: ['M']));
    await tester.tap(find.text('People'));
    await tester.pumpAndSettle();
    expect(find.byType(PeopleScreen), findsOneWidget);
  });

  testWidgets('search opens the memory search', (tester) async {
    await pumpLibrary(tester, counts: const LibraryCounts());
    await tester.tap(find.text('Search what you heard'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(MemorySearchScreen), findsOneWidget);
  });

  testWidgets('search over the whole memory, from the Library', (tester) async {
    final api = FakeMemoryApi()
      ..conversations = [ConversationCard(id: 'c1', startedAt: DateTime(2026, 11, 17, 9))]
      ..searchResults = MemorySearchResults(
        conversations: [
          ConversationCard(
              id: 'hit', startedAt: DateTime(2026, 11, 12, 9), title: 'Atlas kickoff'),
        ],
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
    late void Function() runSearch;
    final memories = MemoriesController(
      api: api,
      debounceScheduler: (delay, callback) {
        runSearch = callback;
        return () {};
      },
    );
    await pumpLibrary(tester,
        counts: const LibraryCounts(), api: api, controller: memories);
    expect(find.byKey(const Key('memories-search')), findsNothing);
    await tester.tap(find.text('Search what you heard'), warnIfMissed: false);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('memories-search')), 'atlas');
    await tester.pump();
    expect(find.byKey(const Key('search-loading')), findsOneWidget);
    runSearch();
    await tester.pumpAndSettle();

    expect(find.widgetWithText(PanelHeader, 'Conversations'), findsOneWidget);
    expect(find.text('Atlas kickoff'), findsOneWidget);
    expect(find.text('Atlas dashboard'), findsOneWidget);
    await tester.tap(find.text('Atlas dashboard'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationDetailScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    api.searchResults = const MemorySearchResults(conversations: [], entities: []);
    await tester.enterText(find.byKey(const Key('memories-search')), 'zzz');
    await tester.pump();
    runSearch();
    await tester.pumpAndSettle();
    expect(find.text('No results'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memories-search-clear')));
    await tester.pumpAndSettle();
    expect(find.text('No results'), findsNothing);

    // Back in the Library, the search is over
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(memories.state.query, isEmpty);
    expect(find.byType(MemorySearchScreen), findsNothing);
  });

  testWidgets(
      'this week lists days and opens one; earlier days and the week are reachable',
      (tester) async {
    final api = _WeekApi()
      ..conversations = [
        ConversationCard(
            id: 'a',
            startedAt: DateTime(2026, 11, 17, 9),
            people: const ['Marco']),
        ConversationCard(id: 'b', startedAt: DateTime(2026, 11, 2, 9)),
      ];
    await pumpLibrary(tester, counts: const LibraryCounts(), api: api);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('1 conversation · Marco'), findsOneWidget);
    expect(find.text('A busy week'), findsOneWidget);
    await tester.tap(find.text('1 conversation · Marco'));
    await tester.pumpAndSettle();
    expect(find.byType(DayScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Earlier'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('earlier-2026-11-02')), findsOneWidget);
  });

  testWidgets('the counts reload on pull to refresh', (tester) async {
    var loads = 0;
    await pumpLibrary(tester,
        counts: const LibraryCounts(), onLoad: () => loads++);
    expect(loads, 1);
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('at the largest text size the Library does not overflow',
      (tester) async {
    await pumpLibrary(tester,
        counts: const LibraryCounts(people: 14, faces: ['M', 'G', 'P']),
        textScaler: const TextScaler.linear(2.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a day row shows its day number in a tile', (tester) async {
    final api = FakeMemoryApi()
      ..conversations = [
        ConversationCard(id: 'a', startedAt: DateTime(2026, 11, 15, 9))
      ];
    await pumpLibrary(tester, counts: const LibraryCounts(), api: api);
    expect(find.text('15'), findsOneWidget);
  });

  testWidgets('the 7th day back is in Earlier, never lost between the two',
      (tester) async {
    final api = FakeMemoryApi()
      ..conversations = [
        ConversationCard(id: 'a', startedAt: DateTime(2027, 3, 26, 9)),
        ConversationCard(id: 'b', startedAt: DateTime(2027, 3, 25, 9)),
      ];
    await pumpLibrary(tester,
        counts: const LibraryCounts(), api: api, at: DateTime(2027, 4, 1, 18));
    expect(find.byKey(const Key('library-day-2027-03-26')), findsOneWidget);
    await tester.tap(find.text('Earlier'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('earlier-2027-03-25')), findsOneWidget);
    expect(find.byKey(const Key('earlier-2027-03-26')), findsNothing);
  });

  testWidgets('the counts load when the tab is first shown and again each time',
      (tester) async {
    var loads = 0;
    await pumpLibrary(tester,
        counts: const LibraryCounts(), onLoad: () => loads++, active: false);
    expect(loads, 0);
    _setActive(true);
    await tester.pumpAndSettle();
    expect(loads, 1);
    _setActive(false);
    await tester.pumpAndSettle();
    _setActive(true);
    await tester.pumpAndSettle();
    expect(loads, 2);
  });
}
