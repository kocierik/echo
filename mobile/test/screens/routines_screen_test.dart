import 'package:echo_app/models/routine.dart';
import 'package:echo_app/models/routine_run.dart';
import 'package:echo_app/screens/settings/routines_screen.dart';
import 'package:echo_app/services/api/routines_api.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 22, 12);

Routine _routine({
  String id = 'r1',
  bool active = true,
  String? lastStatus,
  String? lastAnswer,
  String mode = 'always',
}) =>
    Routine.fromJson({
      'id': id,
      'mode': mode,
      'instruction': 'dimmi che tempo fa a Milano',
      'schedule_text': 'Every day at 07:00',
      'active': active,
      'next_run_at': DateTime(2026, 10, 23, 7).toUtc().toIso8601String(),
      'last_run_at': lastStatus == null ? null : DateTime(2026, 10, 22, 7).toUtc().toIso8601String(),
      'last_status': lastStatus,
      'last_answer': lastAnswer,
    });

final class _FakeRoutinesApi implements RoutinesApi {
  _FakeRoutinesApi(this.routines);

  List<Routine> routines;
  final changes = <(String, bool)>[];
  final deletes = <String>[];
  List<RoutineRun> runs = const [];
  final runRequests = <(String?, int)>[];
  final asked = <String>[];

  @override
  Future<List<Routine>> listRoutines() async => routines;

  @override
  Future<Routine> setRoutineActive(String id, bool active) async {
    changes.add((id, active));
    final routine = routines.firstWhere((r) => r.id == id);
    return routine.copyWith(active: active);
  }

  @override
  Future<void> deleteRoutine(String id) async {
    deletes.add(id);
    routines = routines.where((r) => r.id != id).toList();
  }

  @override
  Future<RoutineRunPage> listRoutineRuns({
    String? routineId,
    DateTime? since,
    DateTime? before,
    int limit = 30,
  }) async {
    runRequests.add((routineId, limit));
    return RoutineRunPage(items: runs);
  }

  @override
  Future<String> askAboutRoutineRun(String runId) async {
    asked.add(runId);
    return 'thread-1';
  }
}

final _opened = <String>[];

Future<void> _show(WidgetTester tester, RoutinesApi api) async {
  _opened.clear();
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    home: RoutinesScreen(
      api: api,
      clock: () => _now,
      onOpenResults: (id) => _opened.add('results $id'),
      onOpenThread: (id) => _opened.add('thread $id'),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists what, when, next run and the last result', (tester) async {
    await _show(tester, _FakeRoutinesApi([
      _routine(lastStatus: 'ok', lastAnswer: 'Oggi a Milano sole, 19 °C.'),
      _routine(id: 'r2', lastStatus: 'failed'),
    ]));

    expect(find.text('dimmi che tempo fa a Milano'), findsNWidgets(2));
    expect(find.text('Every day at 07:00'), findsNWidgets(2));
    expect(find.textContaining('Next: Tomorrow at 07:00'), findsNWidgets(2));
    expect(find.textContaining('Oggi a Milano sole'), findsOneWidget);
    expect(find.text('Could not run'), findsOneWidget);
    expect(find.textContaining('arrive as a notification'), findsOneWidget);
  });

  testWidgets('each routine says when it speaks', (tester) async {
    await _show(tester, _FakeRoutinesApi([
      _routine(mode: 'only_new'),
      _routine(id: 'r2', mode: 'only_if'),
      _routine(id: 'r3'),
    ]));

    expect(find.text('Tells you only what is new'), findsOneWidget);
    expect(find.text('Tells you only if…'), findsOneWidget);
    expect(find.text('Always tells you'), findsOneWidget);
  });

  testWidgets('a quiet last run says it checked; a missed one says so', (tester) async {
    await _show(tester, _FakeRoutinesApi([
      _routine(lastStatus: 'nothing'),
      _routine(id: 'r2', lastStatus: 'skipped'),
    ]));

    expect(find.text('Checked, nothing new'), findsOneWidget);
    expect(find.text('Missed while Echo was offline'), findsOneWidget);
  });

  testWidgets('See all results opens Ask on that routine', (tester) async {
    await _show(tester, _FakeRoutinesApi([_routine(lastStatus: 'ok', lastAnswer: 'Sole.')]));

    await tester.tap(find.byKey(const Key('routine-results-r1')));
    await tester.pumpAndSettle();

    expect(_opened, ['results r1']);
  });

  testWidgets('the last result opens in full, and can be asked about', (tester) async {
    final long = 'Oggi a Milano sole, 19 °C, vento debole da nord-est e niente pioggia. ' * 8;
    final api = _FakeRoutinesApi([_routine(lastStatus: 'ok', lastAnswer: long)])
      ..runs = [
        RoutineRun(
          id: 'run-1',
          routineId: 'r1',
          instruction: 'dimmi che tempo fa a Milano',
          mode: 'always',
          scheduleText: 'Every day at 07:00',
          ranAt: DateTime(2026, 10, 22, 7),
          status: 'reported',
          text: long,
        ),
      ];
    await _show(tester, api);

    await tester.tap(find.byKey(const Key('routine-last-r1')));
    await tester.pumpAndSettle();

    expect(api.runRequests, [('r1', 1)]);
    expect(tester.widget<Text>(find.text(long).last).maxLines, isNull);
    await tester.ensureVisible(find.byKey(const Key('run-ask-about')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('run-ask-about')));
    await tester.pumpAndSettle();

    expect(api.asked, ['run-1']);
    expect(_opened, ['thread thread-1']);
  });

  testWidgets('a last result without a run of its own still opens, with nothing to ask',
      (tester) async {
    await _show(tester, _FakeRoutinesApi([_routine(lastStatus: 'ok', lastAnswer: 'Sole.')]));

    await tester.tap(find.byKey(const Key('routine-last-r1')));
    await tester.pumpAndSettle();

    expect(find.text('Sole.'), findsNWidgets(2));
    expect(find.byKey(const Key('run-ask-about')), findsNothing);
  });

  testWidgets('the switch pauses and resumes', (tester) async {
    final api = _FakeRoutinesApi([_routine()]);
    await _show(tester, api);

    await tester.tap(find.byKey(const Key('routine-r1')));
    await tester.pumpAndSettle();

    expect(api.changes, [('r1', false)]);
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('delete asks first', (tester) async {
    final api = _FakeRoutinesApi([_routine()]);
    await _show(tester, api);

    await tester.tap(find.byTooltip('Delete routine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.deletes, isEmpty);

    await tester.tap(find.byTooltip('Delete routine'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(api.deletes, ['r1']);
    expect(find.text('dimmi che tempo fa a Milano'), findsNothing);
  });

  testWidgets('with none, it says how to ask for one', (tester) async {
    await _show(tester, _FakeRoutinesApi([]));

    expect(find.textContaining('Hey Echo, every morning at 7'), findsOneWidget);
  });
}
