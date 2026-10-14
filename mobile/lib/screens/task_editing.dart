import 'package:flutter/material.dart';

import '../models/task_item.dart';
import '../services/api_exception.dart';
import '../services/api_service.dart';

/// Completing and dropping tasks in place on a screen that loaded them: changes
/// show at once and are undone, with a message, when the server refuses.
mixin TaskEditing<T extends StatefulWidget> on State<T> {
  MemoryApi get taskApi;

  /// Tasks as changed here, by id: a changed task, or null once dropped.
  final Map<String, TaskItem?> _overrides = {};
  final Set<String> _busy = {};

  bool isTaskBusy(TaskItem task) => _busy.contains(task.id);

  /// [loaded] with this screen's changes applied, in the same order.
  List<TaskItem> editedTasks(Iterable<TaskItem> loaded) {
    final tasks = <TaskItem>[];
    for (final task in loaded) {
      if (!_overrides.containsKey(task.id)) {
        tasks.add(task);
      } else if (_overrides[task.id] case final changed?) {
        tasks.add(changed);
      }
    }
    return tasks;
  }

  /// Forget local changes, after reloading from the server.
  void resetTaskEdits() => _overrides.clear();

  Future<void> toggleTask(TaskItem task) => _change(
        task,
        task.copyWithDone(!task.done),
        () => taskApi.setTaskDone(task, !task.done),
        'Could not update the task.',
      );

  Future<void> dismissTask(TaskItem task) => _change(
        task,
        null,
        () => taskApi.deleteEntity(task.id),
        'Could not remove the task.',
      );

  Future<void> _change(
    TaskItem task,
    TaskItem? optimistic,
    Future<void> Function() call,
    String failure,
  ) async {
    if (_busy.contains(task.id)) return;
    setState(() {
      _busy.add(task.id);
      _overrides[task.id] = optimistic;
    });
    try {
      await call();
    } catch (error) {
      if (!mounted) return;
      setState(() => _overrides[task.id] = task);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(userMessage(error, failure))));
    } finally {
      if (mounted) setState(() => _busy.remove(task.id));
    }
  }
}
