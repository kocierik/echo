import 'package:echo_app/models/routine.dart';
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
}) =>
    Routine.fromJson({
      'id': id,
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
}

Future<void> _show(WidgetTester tester, RoutinesApi api) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    home: RoutinesScreen(api: api, clock: () => _now),
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
