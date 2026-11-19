import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/screens/day_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/screens/library_screen.dart';
import 'package:echo_app/screens/memory_search_screen.dart';
import 'package:echo_app/screens/people_screen.dart';
import 'package:echo_app/services/library_counts.dart';
import 'package:echo_app/services/memory/memories_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

class _WeekApi extends FakeMemoryApi implements WeeklySummaryApi {
  @override
  Future<WeeklySummary?> getLatestWeeklySummary() async =>
      WeeklySummary(weekStart: DateTime(2026, 11, 9), summary: 'A busy week');
}

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
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = api ?? FakeMemoryApi();
    final memories = MemoriesController(api: fake);
    await memories.initialize();
    addTearDown(memories.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: LibraryScreen(
        loadCounts: () async {
          onLoad?.call();
          return counts;
        },
        memories: memories,
        api: fake,
        placesOn: placesOn,
        clock: () => now,
      ),
    ));
    await tester.pumpAndSettle();
    return memories;
  }

  testWidgets('the tiles show their counts, and a dash for an unknown one', (tester) async {
    await pumpLibrary(
      tester,
      counts: const LibraryCounts(
          people: 14, faces: ['M', 'G'], openTasks: 3, visitsThisWeek: 8, documents: 3),
    );
    expect(find.text('14 saved'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('3 open'), findsOneWidget);
    expect(find.text('8 this week'), findsOneWidget);
    expect(find.text('People and topics'), findsOneWidget);
  });

  testWidgets('places off says Off', (tester) async {
    await pumpLibrary(tester,
        counts: const LibraryCounts(visitsThisWeek: null), placesOn: ValueNotifier(false));
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('People opens the people page, inside Library', (tester) async {
    await pumpLibrary(tester, counts: const LibraryCounts(people: 1, faces: ['M']));
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

  testWidgets('this week lists days and opens one; earlier days and the week are reachable',
      (tester) async {
    final api = _WeekApi()
      ..conversations = [
        ConversationCard(id: 'a', startedAt: DateTime(2026, 11, 17, 9), people: const ['Marco']),
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
    await pumpLibrary(tester, counts: const LibraryCounts(), onLoad: () => loads++);
    expect(loads, 1);
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('at the largest text size the Library does not overflow', (tester) async {
    await pumpLibrary(tester,
        counts: const LibraryCounts(people: 14, faces: ['M', 'G', 'P']),
        textScaler: const TextScaler.linear(2.0));
    expect(tester.takeException(), isNull);
  });
}
