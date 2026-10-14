import 'package:flutter/material.dart';

import '../models/task_item.dart';
import '../models/today_insights.dart';
import '../theme/app_theme.dart';
import 'sections.dart';

/// Today's "Open tasks" section: up to [maxVisible] tasks, each completable.
final class TodayTasksSection extends StatelessWidget {
  const TodayTasksSection({
    required this.loading,
    required this.tasks,
    required this.error,
    required this.completingIds,
    required this.onRetry,
    required this.onComplete,
    this.maxVisible = 3,
    super.key,
  });

  final bool loading;
  final List<TaskItem> tasks;
  final String? error;
  final Set<String> completingIds;
  final VoidCallback onRetry;
  final void Function(TaskItem task) onComplete;
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final hidden = tasks.length - maxVisible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Open tasks',
          trailing: hidden > 0 ? '+$hidden more' : null,
        ),
        Divider(color: palette.border),
        if (loading)
          const SectionLoading(key: Key('tasks-loading'), label: 'Loading open tasks')
        else if (error != null)
          SectionError(
            message: error!,
            retryKey: const Key('tasks-retry'),
            onRetry: onRetry,
          )
        else if (tasks.isEmpty)
          const SectionEmpty(message: 'No open tasks.')
        else
          for (final task in tasks.take(maxVisible))
            _TaskRow(
              task: task,
              completing: completingIds.contains(task.id),
              onComplete: () => onComplete(task),
            ),
      ],
    );
  }
}

/// Today's "Daily summary" section with the latest digest.
final class TodaySummarySection extends StatelessWidget {
  const TodaySummarySection({
    required this.loading,
    required this.summary,
    required this.error,
    required this.onRetry,
    this.today,
    super.key,
  });

  final bool loading;
  final DailySummary? summary;
  final String? error;
  final VoidCallback onRetry;

  /// Injectable "now" for tests; defaults to the current day.
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final digest = summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Daily summary',
          trailing: digest == null ? null : _dayLabel(digest.date, today ?? DateTime.now()),
        ),
        Divider(color: palette.border),
        if (loading)
          const SectionLoading(key: Key('summary-loading'), label: 'Loading daily summary')
        else if (error != null)
          SectionError(
            message: error!,
            retryKey: const Key('summary-retry'),
            onRetry: onRetry,
          )
        else if (digest == null)
          const SectionEmpty(
            message: 'No summary yet. Echo writes one each night for the day before.',
          )
        else
          Padding(
            key: const Key('summary-content'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              digest.summary,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }
}

final class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.completing,
    required this.onComplete,
  });

  final TaskItem task;
  final bool completing;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final due = task.dueDate;
    return Row(
      key: Key('task-${task.id}'),
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: completing
              ? Padding(
                  padding: const EdgeInsets.all(13),
                  child: CircularProgressIndicator(strokeWidth: 2, color: palette.blue),
                )
              : IconButton(
                  key: Key('task-complete-${task.id}'),
                  tooltip: 'Mark "${task.name}" as done',
                  onPressed: onComplete,
                  icon: Icon(Icons.radio_button_unchecked_rounded, color: palette.text2),
                ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            task.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        if (due != null) ...[
          const SizedBox(width: 8),
          Text(
            _shortDate(due),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: palette.text2,
                ),
          ),
        ],
      ],
    );
  }
}

String _dayLabel(DateTime day, DateTime today) {
  final date = DateTime(day.year, day.month, day.day);
  final now = DateTime(today.year, today.month, today.day);
  final difference = now.difference(date).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  return _shortDate(day);
}

String _shortDate(DateTime value) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[value.month - 1]} ${value.day}';
}
