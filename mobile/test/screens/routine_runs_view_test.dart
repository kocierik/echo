import 'package:echo_app/models/routine.dart';
import 'package:echo_app/models/routine_run.dart';
import 'package:echo_app/screens/routine_runs_view.dart';
import 'package:echo_app/services/api/routines_api.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RoutineRun _run(
  String id, {
  required DateTime at,
  String status = 'reported',
  String? text,
  String routineId = 'rt1',
  String instruction = 'dimmi se piove domani',
  List<RoutineSource> sources = const [],
}) =>
    RoutineRun(
      id: id,
      routineId: routineId,
      instruction: instruction,
      mode: 'only_if',
      scheduleText: 'Every day at 07:00',
      ranAt: at,
      status: status,
      text: text ?? (status == 'reported' || status == 'failed' ? 'Text of $id' : null),
      sources: sources,
    );

Routine _routine(String id, String instruction) => Routine.fromJson({
      'id': id,
      'instruction': instruction,
      'schedule_text': 'Every day at 07:00',
      'active': true,
      'next_run_at': '2026-10-29T06:00:00Z',
    });

final class _Api implements RoutinesApi {
  _Api(this.pages);

  List<Routine> routines = [
    _routine('rt1', 'dimmi se piove domani'),
    _routine('rt2', 'nuove posizioni'),
  ];

  /// The pages in order; the filter keeps a routine's runs.
  final List<RoutineRunPage> pages;
  final calls = <(String?, DateTime?)>[];

  @override
  Future<RoutineRunPage> listRoutineRuns({
    String? routineId,
    DateTime? since,
    DateTime? before,
    int limit = 30,
  }) async {
    calls.add((routineId, before));
    final page = before == null ? pages.first : pages[1];
    return RoutineRunPage(
      items: [
        for (final run in page.items)
          if (routineId == null || run.routineId == routineId) run,
      ],
      nextBefore: page.nextBefore,
    );
  }

  @override
  Future<List<Routine>> listRoutines() async => routines;

  @override
  Future<String> askAboutRoutineRun(String runId) async => 'thread-1';

  @override
  Future<Routine> setRoutineActive(String id, bool active) => throw UnimplementedError();

  @override
  Future<void> deleteRoutine(String id) => throw UnimplementedError();
}

void main() {
  final today = DateTime.now();
  final yesterday = today.subtract(const Duration(days: 1));
  final long = 'Nuove posizioni backend a Milano e da remoto, con link e dettagli. ' * 20;

  late List<String?> filters;
  late List<String> asked;

  Future<void> pump(WidgetTester tester, _Api api, {String? routineId}) async {
    // Tall enough for every row to be built
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 4000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    filters = [];
    asked = [];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: RoutineRunsView(
          api: api,
          routineId: routineId,
          onFilter: filters.add,
          onAskAbout: (run) async => asked.add(run.id),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('runs by day, newest first, with their full text and sources', (tester) async {
    await pump(
      tester,
      _Api([
        RoutineRunPage(items: [
          _run('a',
              at: today,
              text: long,
              routineId: 'rt2',
              instruction: 'nuove posizioni',
              sources: [RoutineSource(title: 'Jobs', url: Uri.parse('https://jobs.example/1'))]),
          _run('b', at: today, status: 'nothing'),
          _run('c', at: yesterday, status: 'failed', text: 'Non riuscito.'),
          _run('d', at: yesterday, status: 'skipped'),
        ]),
      ]),
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.text(long), findsOneWidget);
    expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
    // Ask about this only where there is a result
    expect(find.byKey(const Key('ask-about-a')), findsOneWidget);
    expect(find.text('Jobs'), findsOneWidget);
    expect(find.textContaining('checked, nothing new'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Non riuscito.')).style?.color,
      AppTheme.light.extension<EchoPalette>()!.red,
    );
    expect(find.textContaining('Missed at'), findsOneWidget);
    expect(find.byKey(const Key('ask-about-c')), findsNothing);
  });

  testWidgets('a chip filters on one routine', (tester) async {
    final api = _Api([
      RoutineRunPage(items: [
        _run('a', at: today),
        _run('b', at: today, routineId: 'rt2', instruction: 'nuove posizioni'),
      ]),
    ]);
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('routines-filter-rt2')));
    await tester.pumpAndSettle();

    expect(filters, ['rt2']);
  });

  testWidgets('a routine given from outside is the one shown', (tester) async {
    final api = _Api([
      RoutineRunPage(items: [
        _run('a', at: today),
        _run('b', at: today, routineId: 'rt2', instruction: 'nuove posizioni'),
      ]),
    ]);
    await pump(tester, api, routineId: 'rt2');

    expect(api.calls.first.$1, 'rt2');
    expect(find.text('Text of b'), findsOneWidget);
    expect(find.text('Text of a'), findsNothing);
  });

  testWidgets('a filter on a routine no longer there can be cleared', (tester) async {
    final api = _Api([const RoutineRunPage(items: [])])
      ..routines = [_routine('rt1', 'dimmi se piove domani')];
    await pump(tester, api, routineId: 'gone');

    await tester.tap(find.byKey(const Key('routines-filter-all')));
    await tester.pumpAndSettle();

    expect(filters, [null]);
  });

  testWidgets('Ask about this asks about that run', (tester) async {
    await pump(
        tester,
        _Api([
          RoutineRunPage(items: [_run('a', at: today)])
        ]));

    await tester.tap(find.byKey(const Key('ask-about-a')));
    await tester.pumpAndSettle();

    expect(asked, ['a']);
  });

  testWidgets('earlier results load at the end of the list', (tester) async {
    final next = DateTime(2026, 10, 20);
    final api = _Api([
      RoutineRunPage(items: [_run('a', at: today)], nextBefore: next),
      RoutineRunPage(items: [_run('z', at: DateTime(2026, 10, 19, 7))]),
    ]);
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('routines-more')));
    await tester.pumpAndSettle();

    expect(api.calls.last.$2, next);
    expect(find.text('Text of z'), findsOneWidget);
    expect(find.byKey(const Key('routines-more')), findsNothing);
  });

  testWidgets('with no results it says where they will show up', (tester) async {
    await pump(tester, _Api([const RoutineRunPage(items: [])]));

    expect(find.text("Your routines' results show up here."), findsOneWidget);
  });
}
