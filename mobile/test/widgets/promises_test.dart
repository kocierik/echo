import 'package:echo_app/models/task_item.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/today_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TaskItem _task(String id,
        {bool promise = false, String? to, DateTime? due, DateTime? created}) =>
    TaskItem(
      id: id,
      name: 'Task $id',
      dueDate: due,
      createdAt: created,
      metadata: {
        if (promise) 'promise': true,
        if (to != null) 'promise_to': to,
        if (due != null) 'due_date': due.toIso8601String().substring(0, 10),
      },
    );

void main() {
  final now = DateTime(2026, 10, 15, 10);

  test('promises: the old ones without a date first, then by date', () {
    final open = [
      _task('fresh',
          promise: true, created: now.subtract(const Duration(days: 1))),
      _task('later', promise: true, due: DateTime(2026, 10, 20)),
      _task('soon', promise: true, due: DateTime(2026, 10, 16)),
      _task('stale',
          promise: true, created: now.subtract(const Duration(days: 5))),
      _task('plain', due: DateTime(2026, 10, 15)),
    ];

    expect(openPromises(open, now).map((t) => t.id),
        ['stale', 'soon', 'later', 'fresh']);
    // Promises are not repeated among Today's tasks
    expect(todayTasks(open, now).map((t) => t.id), ['plain']);
  });

  test('To do today: promises due, stale or made today, then the tasks', () {
    final open = [
      _task('plain', due: DateTime(2026, 10, 15)),
      _task('later', promise: true, due: DateTime(2026, 10, 20)),
      _task('due', promise: true, due: DateTime(2026, 10, 15)),
      _task('stale', promise: true, created: now.subtract(const Duration(days: 5))),
      _task('new', promise: true, created: DateTime(2026, 10, 15, 9)),
      _task('recent', promise: true, created: now.subtract(const Duration(days: 1))),
    ];

    expect(todayTodo(open, now).map((t) => t.id), ['stale', 'due', 'new', 'plain']);
  });

  testWidgets('a promise says to whom', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: TodoPanel(
          loading: false,
          tasks: [_task('p', promise: true, to: 'Marco')],
          error: null,
          busy: (_) => false,
          onRetry: () {},
          onToggle: (_) {},
          onDismiss: (_) {},
          onSeeAll: () {},
          now: now,
        ),
      ),
    ));
    expect(find.text('To do today'), findsOneWidget);
    expect(find.text('Promised to Marco'), findsOneWidget);
  });
}
