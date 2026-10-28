import 'package:echo_app/models/routine_run.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/routine_run_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RoutineRun _run({
  String status = 'reported',
  String? text = 'Domani piove dalle 15.',
  List<RoutineSource> sources = const [],
}) =>
    RoutineRun(
      id: 'r1',
      routineId: 'rt1',
      instruction: 'dimmi se piove domani',
      mode: 'only_if',
      scheduleText: 'Every day at 07:00',
      ranAt: DateTime(2026, 10, 28, 7),
      status: status,
      text: text,
      sources: sources,
    );

void main() {
  late int asked;

  Future<void> open(WidgetTester tester, RoutineRun run) async {
    asked = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRoutineRunSheet(context, run, onAskAbout: () async => asked++),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the whole text, the routine, its mode and time', (tester) async {
    final long = 'Domani a Milano piove dalle 15 alle 21, porta l’ombrello. ' * 35;
    await open(tester, _run(text: long));

    expect(long.length, greaterThan(2000));
    expect(find.text(long), findsOneWidget);
    expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
    expect(find.text('dimmi se piove domani'), findsOneWidget);
    expect(find.textContaining('Tells you only when its condition holds'), findsOneWidget);
    expect(find.textContaining('07:00'), findsOneWidget);
  });

  testWidgets('its sources are listed', (tester) async {
    await open(
      tester,
      _run(sources: [
        RoutineSource(title: 'Meteo Milano', url: Uri.parse('https://meteo.it/milano')),
        const RoutineSource(title: 'No link'),
      ]),
    );

    expect(find.text('Meteo Milano'), findsOneWidget);
    expect(find.text('meteo.it'), findsOneWidget);
    expect(find.text('No link'), findsOneWidget);
  });

  testWidgets('Ask about this closes the sheet and asks once', (tester) async {
    await open(tester, _run());

    await tester.tap(find.byKey(const Key('run-ask-about')));
    await tester.pumpAndSettle();

    expect(asked, 1);
    expect(find.text('dimmi se piove domani'), findsNothing);
  });

  testWidgets('a missed run says so, with nothing to ask about', (tester) async {
    await open(tester, _run(status: 'skipped', text: null));

    expect(find.text("Missed at 07:00: Echo's server was off"), findsOneWidget);
    expect(find.byKey(const Key('run-ask-about')), findsNothing);
  });

  testWidgets('a quiet run says it checked, with nothing to ask about', (tester) async {
    await open(tester, _run(status: 'nothing', text: null));

    expect(find.text('Checked, nothing new'), findsOneWidget);
    expect(find.byKey(const Key('run-ask-about')), findsNothing);
  });

  testWidgets('a failed run is red, with nothing to ask about', (tester) async {
    await open(tester, _run(status: 'failed', text: 'Non sono riuscito.'));

    final failed = tester.widget<Text>(find.text('Non sono riuscito.'));
    expect(failed.style?.color, AppTheme.light.extension<EchoPalette>()!.red);
    expect(find.byKey(const Key('run-ask-about')), findsNothing);
  });
}
