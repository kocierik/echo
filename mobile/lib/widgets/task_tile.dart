import 'package:flutter/material.dart';

import '../models/task_item.dart';
import '../theme/app_theme.dart';
import 'formatting.dart';
import 'memory_entity_row.dart';

/// A task with its checkbox, due day and the sentence it came from. The menu
/// offers "Not a task" (Echo misheard an intention as a task) and, when the
/// task has one, opening its conversation.
final class TaskTile extends StatelessWidget {
  const TaskTile({
    required this.task,
    required this.onToggle,
    this.busy = false,
    this.onDismiss,
    this.onOpenConversation,
    this.now,
    this.padding = const EdgeInsets.only(left: 8, right: 4),
    super.key,
  });

  final TaskItem task;
  final VoidCallback onToggle;
  final bool busy;
  final VoidCallback? onDismiss;
  final VoidCallback? onOpenConversation;

  /// Injectable "now" for tests.
  final DateTime? now;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final due = task.dueDate;
    final today = dayOf(now ?? DateTime.now());
    final overdue = !task.done && due != null && dayOf(due).isBefore(today);
    final source = task.sourceText;

    return Padding(
      key: Key('task-${task.id}'),
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 44,
            child: busy
                ? Padding(
                    padding: const EdgeInsets.all(13),
                    child: CircularProgressIndicator(strokeWidth: 2, color: palette.blue),
                  )
                : IconButton(
                    key: Key('task-toggle-${task.id}'),
                    tooltip: task.done
                        ? 'Mark "${task.name}" as not done'
                        : 'Mark "${task.name}" as done',
                    onPressed: onToggle,
                    icon: Icon(
                      task.done
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: task.done ? palette.green : palette.text2,
                    ),
                  ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.name,
                    style: textTheme.bodyMedium?.copyWith(
                      height: 1.35,
                      color: task.done ? palette.text2 : null,
                      decoration: task.done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (due != null)
                    Text(
                      overdue ? 'Overdue · ${shortDate(due)}' : dayLabel(due, today),
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        color: overdue ? palette.red : null,
                        fontWeight: overdue ? FontWeight.w600 : null,
                      ),
                    ),
                  if (source != null) SourceQuote(text: source),
                ],
              ),
            ),
          ),
          if (onDismiss != null || onOpenConversation != null)
            PopupMenuButton<_TaskAction>(
              key: Key('task-menu-${task.id}'),
              tooltip: 'More for "${task.name}"',
              enabled: !busy,
              icon: Icon(Icons.more_horiz_rounded, color: palette.text2),
              onSelected: (action) => switch (action) {
                _TaskAction.open => onOpenConversation?.call(),
                _TaskAction.dismiss => onDismiss?.call(),
              },
              itemBuilder: (context) => [
                if (onOpenConversation != null)
                  const PopupMenuItem(
                    value: _TaskAction.open,
                    child: Text('Open conversation'),
                  ),
                if (onDismiss != null)
                  PopupMenuItem(
                    key: Key('task-dismiss-${task.id}'),
                    value: _TaskAction.dismiss,
                    child: Text('Not a task', style: TextStyle(color: palette.red)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

enum _TaskAction { open, dismiss }
