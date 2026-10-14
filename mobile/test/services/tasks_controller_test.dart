import 'package:echo_app/services/tasks_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  group('groupTasks', () {
    final now = DateTime(2026, 10, 14, 18); // a Wednesday

    test('buckets by due day and drops empty buckets', () {
      final groups = groupTasks([
        task('none', 'No date', createdAt: DateTime(2026, 10, 1)),
        task('later', 'Later', due: DateTime(2026, 10, 30)),
        task('week', 'This week', due: DateTime(2026, 10, 18)),
        task('tomorrow', 'Tomorrow', due: DateTime(2026, 10, 15)),
        task('today', 'Today', due: DateTime(2026, 10, 14)),
        task('late', 'Overdue', due: DateTime(2026, 10, 2)),
      ], now);

      expect(groups.map((g) => g.bucket), [
        TaskBucket.overdue,
        TaskBucket.today,
        TaskBucket.tomorrow,
        TaskBucket.thisWeek,
        TaskBucket.later,
        TaskBucket.noDate,
      ]);
      expect(groups.map((g) => g.tasks.single.id), [
        'late', 'today', 'tomorrow', 'week', 'later', 'none',
      ]);
    });

    test('sorts by due day, and undated tasks newest first', () {
      final groups = groupTasks([
        task('b', 'B', due: DateTime(2026, 10, 19)),
        task('a', 'A', due: DateTime(2026, 10, 17)),
        task('old', 'Old', createdAt: DateTime(2026, 10, 1)),
        task('new', 'New', createdAt: DateTime(2026, 10, 13)),
      ], now);

      expect(groups[0].tasks.map((t) => t.id), ['a', 'b']);
      expect(groups[1].tasks.map((t) => t.id), ['new', 'old']);
    });

    test('a week from today is later, six days is this week', () {
      final groups = groupTasks([
        task('six', 'Six', due: DateTime(2026, 10, 20)),
        task('seven', 'Seven', due: DateTime(2026, 10, 21)),
      ], now);

      expect(groups.map((g) => g.bucket), [TaskBucket.thisWeek, TaskBucket.later]);
    });
  });

  group('TasksController', () {
    test('loads open and done tasks', () async {
      final api = FakeMemoryApi(
        openTasks: [task('o', 'Open')],
        doneTasks: [task('d', 'Done', done: true)],
      );
      final controller = TasksController(api: api);
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.state.loading, isFalse);
      expect(controller.state.open.map((t) => t.id), ['o']);
      expect(controller.state.done.map((t) => t.id), ['d']);
    });

    test('a load failure is reported', () async {
      final api = FakeMemoryApi()..listError = serverError('Down');
      final controller = TasksController(api: api);
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.state.error, 'Down');
      expect(controller.state.loading, isFalse);
    });

    test('completing moves the task to done with done metadata', () async {
      final api = FakeMemoryApi(openTasks: [task('o', 'Open')]);
      final controller = TasksController(api: api);
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.setDone(controller.state.open.single, true);

      expect(controller.state.open, isEmpty);
      expect(controller.state.done.single.done, isTrue);
      expect(controller.state.busyIds, isEmpty);
      expect(api.calls, contains('done o true'));
    });

    test('a failed change puts back only that task', () async {
      final api = FakeMemoryApi(openTasks: [task('a', 'A'), task('b', 'B')]);
      final controller = TasksController(api: api);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.setDone(controller.state.open.last, true); // B done
      api.taskError = serverError('Nope');

      await controller.setDone(controller.state.open.single, true); // A fails

      expect(controller.state.open.map((t) => t.id), ['a']);
      expect(controller.state.open.single.done, isFalse);
      expect(controller.state.done.map((t) => t.id), ['b']);
      expect(controller.state.actionError, 'Nope');
    });

    test('Not a task deletes it, and a failure restores it', () async {
      final api = FakeMemoryApi(openTasks: [task('a', 'A'), task('b', 'B')]);
      final controller = TasksController(api: api);
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.dismiss(controller.state.open.first);
      expect(controller.state.open.map((t) => t.id), ['b']);
      expect(api.calls, contains('delete entity a'));

      api.taskError = serverError('Nope');
      await controller.dismiss(controller.state.open.single);
      expect(controller.state.open.map((t) => t.id), ['b']);
      expect(controller.state.actionError, 'Nope');
    });

    test('reopening a done task moves it back to open', () async {
      final api = FakeMemoryApi(doneTasks: [task('d', 'Done', done: true)]);
      final controller = TasksController(api: api);
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.setDone(controller.state.done.single, false);

      expect(controller.state.done, isEmpty);
      expect(controller.state.open.single.done, isFalse);
    });
  });
}
