import 'package:echo_app/screens/tasks_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  final now = DateTime(2026, 10, 14, 18);

  Future<void> pump(
    WidgetTester tester,
    FakeMemoryApi api, {
    List<String>? opened,
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
          body: TasksScreen(
            api: api,
            clock: () => now,
            openConversation: (context, id) async => opened?.add(id),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  FakeMemoryApi sample() => FakeMemoryApi(
        openTasks: [
          task('late', 'Send the invoice', due: DateTime(2026, 10, 10)),
          task('today', 'Call Ada', due: DateTime(2026, 10, 14),
              source: '[Tu] Oggi devo chiamare Ada.'),
          task('none', 'Buy a plant'),
        ],
        doneTasks: [task('d1', 'Book the flight', done: true)],
      );

  testWidgets('groups open tasks by due day with sources', (tester) async {
    await pump(tester, sample());

    expect(find.text('3 open'), findsOneWidget);
    expect(find.text('Overdue · 1'), findsOneWidget);
    expect(find.text('Today · 1'), findsOneWidget);
    expect(find.text('No date · 1'), findsOneWidget);
    expect(find.text('Overdue · Oct 10'), findsOneWidget);
    expect(find.text('“Oggi devo chiamare Ada.”'), findsOneWidget);
    final overdueY = tester.getTopLeft(find.text('Overdue · 1')).dy;
    final todayY = tester.getTopLeft(find.text('Today · 1')).dy;
    expect(overdueY, lessThan(todayY));
    expect(find.text('Book the flight'), findsNothing); // Done is collapsed
  });

  testWidgets('completing shows Undo, which reopens the task', (tester) async {
    final api = sample();
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('task-toggle-today')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('done today true'));
    expect(find.text('Done: Call Ada'), findsOneWidget);
    expect(find.text('Today · 1'), findsNothing);

    await tester.tap(find.byKey(const Key('task-undo')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('done today false'));
    expect(find.text('Today · 1'), findsOneWidget);
  });

  testWidgets('Not a task removes it; a failure brings it back', (tester) async {
    final api = sample();
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('task-menu-none')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-dismiss-none')));
    await tester.pumpAndSettle();
    expect(find.text('Buy a plant'), findsNothing);
    expect(find.text('Removed "Buy a plant" from your tasks.'), findsOneWidget);

    api.taskError = serverError('Server busy');
    await tester.tap(find.byKey(const Key('task-menu-late')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-dismiss-late')));
    await tester.pumpAndSettle();
    expect(find.text('Send the invoice'), findsOneWidget);
    expect(find.text('Server busy'), findsOneWidget);
  });

  testWidgets('a task opens its conversation, and Done expands', (tester) async {
    final opened = <String>[];
    await pump(tester, sample(), opened: opened);

    await tester.tap(find.byKey(const Key('task-menu-today')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    expect(opened, ['c1']);

    await tester.tap(find.byKey(const Key('tasks-done-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Book the flight'), findsOneWidget);
  });

  testWidgets('empty and error states', (tester) async {
    await pump(tester, FakeMemoryApi());
    expect(find.text('No tasks yet'), findsOneWidget);

    final failing = FakeMemoryApi()..listError = serverError('Offline');
    await tester.pumpWidget(const SizedBox()); // a new screen, not the old state
    await pump(tester, failing);
    expect(find.text('Could not load your tasks'), findsOneWidget);
    failing
      ..listError = null
      ..openTasks = [task('a', 'Call Ada')];
    await tester.tap(find.byKey(const Key('tasks-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Call Ada'), findsOneWidget);
  });

  testWidgets('at 2.0 text scale To do does not overflow', (tester) async {
    await pump(tester, sample(), size: const Size(375, 812), textScale: 2.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits 320 wide at 1.3 text scale in light and dark', (tester) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await pump(tester, sample(), theme: theme, size: const Size(320, 640), textScale: 1.3);
      expect(tester.takeException(), isNull);
    }
  });
}
