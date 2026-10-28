import 'package:echo_app/models/routine_run.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/routine_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RoutineRun run(
  String id, {
  String status = 'reported',
  String? text,
  int hour = 7,
  String instruction = 'dimmi se piove domani',
}) =>
    RoutineRun(
      id: id,
      routineId: 'rt-$id',
      instruction: instruction,
      mode: 'only_if',
      scheduleText: 'Every day at 07:00',
      ranAt: DateTime(2026, 10, 28, hour),
      status: status,
      text: text ?? (status == 'reported' || status == 'failed' ? 'Text of $id' : null),
    );

void main() {
  late List<RoutineRun> opened;

  Future<void> pump(WidgetTester tester, List<RoutineRun> runs) async {
    opened = [];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: RoutinesTodayPanel(runs: runs, onOpen: opened.add),
        ),
      ),
    ));
  }

  testWidgets('today panel lists reported and failed runs and counts quiet ones',
      (tester) async {
    await pump(tester, [
      run('a', hour: 7, text: 'Domani piove dalle 15'),
      run('b', status: 'nothing', hour: 8),
      run('c', status: 'failed', hour: 9, instruction: 'nuove posizioni'),
      run('d', status: 'nothing', hour: 10),
      run('e', status: 'skipped', hour: 6),
    ]);

    expect(find.text('From your routines'), findsOneWidget);
    expect(find.text('Domani piove dalle 15'), findsOneWidget);
    expect(find.text('dimmi se piove domani · 07:00'), findsOneWidget);
    // Newest first: the failed one at 9 above the one at 7
    final failed = find.text('Could not run');
    expect(failed, findsOneWidget);
    expect(
      tester.getTopLeft(failed).dy,
      lessThan(tester.getTopLeft(find.text('Domani piove dalle 15')).dy),
    );
    expect(tester.widget<Text>(failed).style?.color, AppTheme.light.extension<EchoPalette>()!.red);
    expect(find.text('nuove posizioni · 09:00'), findsOneWidget);
    expect(find.text('2 checked, nothing new'), findsOneWidget);
    expect(find.text("Missed at 06:00: Echo's server was off"), findsOneWidget);
  });

  testWidgets('today panel with only quiet runs shows one muted line', (tester) async {
    await pump(tester, [run('a', status: 'nothing'), run('b', status: 'nothing', hour: 8)]);

    expect(find.byKey(const Key('routines-today')), findsOneWidget);
    expect(find.text('2 checked, nothing new'), findsOneWidget);
    expect(find.byKey(const Key('routine-run-a')), findsNothing);
    expect(find.byKey(const Key('routine-run-b')), findsNothing);
  });

  testWidgets('one quiet run is said in the singular', (tester) async {
    await pump(tester, [run('a', status: 'nothing')]);

    expect(find.text('1 checked, nothing new'), findsOneWidget);
  });

  testWidgets('a tap on a row opens that run', (tester) async {
    await pump(tester, [run('a'), run('b', hour: 8)]);

    await tester.tap(find.byKey(const Key('routine-run-a')));

    expect(opened.map((r) => r.id), ['a']);
  });

  testWidgets('no runs, no panel', (tester) async {
    await pump(tester, const []);

    expect(find.byKey(const Key('routines-today')), findsNothing);
  });
}
