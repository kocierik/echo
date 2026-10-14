import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/task_item.dart';
import 'api_exception.dart';
import 'api_service.dart';

enum TaskBucket { overdue, today, tomorrow, thisWeek, later, noDate }

extension TaskBucketLabel on TaskBucket {
  String get label => switch (this) {
        TaskBucket.overdue => 'Overdue',
        TaskBucket.today => 'Today',
        TaskBucket.tomorrow => 'Tomorrow',
        TaskBucket.thisWeek => 'This week',
        TaskBucket.later => 'Later',
        TaskBucket.noDate => 'No date',
      };
}

@immutable
final class TaskGroup {
  const TaskGroup(this.bucket, this.tasks);

  final TaskBucket bucket;
  final List<TaskItem> tasks;
}

/// Open tasks by due day relative to [now]: earliest due first; tasks without
/// a date last, newest first. Empty buckets are left out.
List<TaskGroup> groupTasks(List<TaskItem> tasks, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final buckets = <TaskBucket, List<TaskItem>>{};
  for (final task in tasks) {
    buckets.putIfAbsent(_bucketOf(task.dueDate, today), () => []).add(task);
  }
  for (final entry in buckets.entries) {
    entry.value.sort(
      entry.key == TaskBucket.noDate ? _newestFirst : _earliestDueFirst,
    );
  }
  return [
    for (final bucket in TaskBucket.values)
      if (buckets[bucket] case final items?) TaskGroup(bucket, List.unmodifiable(items)),
  ];
}

TaskBucket _bucketOf(DateTime? due, DateTime today) {
  if (due == null) return TaskBucket.noDate;
  final days = DateTime(due.year, due.month, due.day).difference(today).inDays;
  if (days < 0) return TaskBucket.overdue;
  if (days == 0) return TaskBucket.today;
  if (days == 1) return TaskBucket.tomorrow;
  if (days < 7) return TaskBucket.thisWeek;
  return TaskBucket.later;
}

int _earliestDueFirst(TaskItem a, TaskItem b) {
  final byDue = a.dueDate!.compareTo(b.dueDate!);
  return byDue != 0 ? byDue : _newestFirst(a, b);
}

int _newestFirst(TaskItem a, TaskItem b) {
  final left = a.createdAt, right = b.createdAt;
  if (left == null || right == null) return 0;
  return right.compareTo(left);
}

@immutable
final class TasksState {
  const TasksState({
    this.open = const [],
    this.done = const [],
    this.loading = true,
    this.error,
    this.actionError,
    this.busyIds = const {},
  });

  final List<TaskItem> open;
  final List<TaskItem> done;
  final bool loading;

  /// The list could not be loaded.
  final String? error;

  /// A change (complete, undo, Not a task) failed and was rolled back.
  final String? actionError;
  final Set<String> busyIds;

  TasksState copyWith({
    List<TaskItem>? open,
    List<TaskItem>? done,
    bool? loading,
    String? Function()? error,
    String? Function()? actionError,
    Set<String>? busyIds,
  }) {
    return TasksState(
      open: open ?? this.open,
      done: done ?? this.done,
      loading: loading ?? this.loading,
      error: error == null ? this.error : error(),
      actionError: actionError == null ? this.actionError : actionError(),
      busyIds: busyIds ?? this.busyIds,
    );
  }
}

/// The Tasks tab: open and done tasks, completed or dropped optimistically and
/// rolled back when the server refuses.
final class TasksController extends ChangeNotifier {
  TasksController({required MemoryApi api, Stream<Object?>? uploadStream})
      : _api = api {
    // New speech can create tasks (after analysis): refresh quietly
    _uploadSubscription = uploadStream?.listen((_) => unawaited(refresh()));
  }

  static const doneLimit = 50;

  final MemoryApi _api;
  TasksState _state = const TasksState();
  TasksState get state => _state;

  StreamSubscription<Object?>? _uploadSubscription;
  int _generation = 0;
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    _initialized = true;
    return refresh();
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    _emit(_state.copyWith(
      loading: _state.open.isEmpty && _state.done.isEmpty,
      error: () => null,
    ));
    try {
      final results = await Future.wait([
        _api.listTasks(done: false),
        _api.listTasks(done: true, limit: doneLimit),
      ]);
      if (_disposed || generation != _generation) return;
      _emit(_state.copyWith(open: results[0], done: results[1], loading: false));
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _emit(_state.copyWith(
        loading: false,
        error: () => userMessage(error, 'Could not load your tasks.'),
      ));
    }
  }

  /// Marks [task] done (or open again with [done] false).
  Future<void> setDone(TaskItem task, bool done) async {
    if (_state.busyIds.contains(task.id)) return;
    final changed = task.copyWithDone(done);
    _emit(_state.copyWith(
      open: done
          ? _without(_state.open, task.id)
          : [changed, ..._without(_state.open, task.id)],
      done: done
          ? [changed, ..._without(_state.done, task.id)]
          : _without(_state.done, task.id),
      busyIds: {..._state.busyIds, task.id},
      actionError: () => null,
    ));
    try {
      await _api.setTaskDone(task, done);
      _finish(task.id);
    } catch (error) {
      _restore(task, userMessage(error, 'Could not update the task.'));
    }
  }

  /// Drops a wrongly extracted task ("Not a task"): it is deleted from memory.
  Future<void> dismiss(TaskItem task) async {
    if (_state.busyIds.contains(task.id)) return;
    _emit(_state.copyWith(
      open: _without(_state.open, task.id),
      done: _without(_state.done, task.id),
      busyIds: {..._state.busyIds, task.id},
      actionError: () => null,
    ));
    try {
      await _api.deleteEntity(task.id);
      _finish(task.id);
    } catch (error) {
      _restore(task, userMessage(error, 'Could not remove the task.'));
    }
  }

  void clearActionError() => _emit(_state.copyWith(actionError: () => null));

  void _finish(String id) {
    _emit(_state.copyWith(busyIds: {..._state.busyIds}..remove(id)));
  }

  /// Puts [task] back as it was before a failed change, touching no other task.
  void _restore(TaskItem task, String message) {
    final open = _without(_state.open, task.id);
    final done = _without(_state.done, task.id);
    _emit(_state.copyWith(
      open: task.done ? open : [task, ...open],
      done: task.done ? [task, ...done] : done,
      busyIds: {..._state.busyIds}..remove(task.id),
      actionError: () => message,
    ));
  }

  static List<TaskItem> _without(List<TaskItem> tasks, String id) =>
      tasks.where((task) => task.id != id).toList();

  void _emit(TasksState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_uploadSubscription?.cancel());
    super.dispose();
  }
}
