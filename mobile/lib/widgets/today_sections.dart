import 'package:flutter/material.dart';

import '../models/action_models.dart';
import '../models/memory.dart';
import '../models/task_item.dart';
import '../models/today_insights.dart';
import '../theme/app_theme.dart';
import 'action_card.dart';
import 'conversation_card.dart';
import '../utils/formatting.dart';
import 'sections.dart';
import 'task_tile.dart';

/// Tasks for Today: overdue and due today first, then the ones created today
/// (so a misheard one can be dropped while it is fresh).
List<TaskItem> todayTasks(List<TaskItem> open, DateTime now) {
  final today = dayOf(now);
  bool due(TaskItem t) => t.dueDate != null && !dayOf(t.dueDate!).isAfter(today);
  bool createdToday(TaskItem t) => t.createdAt != null && dayOf(t.createdAt!) == today;
  final dueTasks = open.where(due).toList()
    ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
  final fresh = open.where((t) => !due(t) && createdToday(t)).toList();
  return [...dueTasks, ...fresh];
}

/// Today's conversations (and one still going), newest first.
List<ConversationCard> todayConversations(List<ConversationCard> all, DateTime now) {
  final today = dayOf(now);
  return all.where((c) => c.isOpen || dayOf(c.startedAt) == today).toList();
}

/// "Needs you": actions waiting for a Confirm. Hidden when there are none.
final class NeedsYouSection extends StatelessWidget {
  const NeedsYouSection({
    required this.actions,
    required this.busyIds,
    required this.onConfirm,
    required this.onCancel,
    super.key,
  });

  final List<PendingAction> actions;
  final Set<String> busyIds;
  final void Function(PendingAction action) onConfirm;
  final void Function(PendingAction action) onCancel;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('needs-you'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: 'Needs you', trailing: '${actions.length}'),
        for (final action in actions)
          ActionCard(
            action: action,
            busy: busyIds.contains(action.id),
            onConfirm: () => onConfirm(action),
            onCancel: () => onCancel(action),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// "Today so far": a one-line recap and today's conversations.
final class TodayRecapSection extends StatelessWidget {
  const TodayRecapSection({
    required this.loading,
    required this.conversations,
    required this.error,
    required this.onRetry,
    required this.onOpen,
    required this.onSeeAll,
    this.maxVisible = 3,
    super.key,
  });

  final bool loading;

  /// Today's conversations only.
  final List<ConversationCard> conversations;
  final String? error;
  final VoidCallback onRetry;
  final void Function(ConversationCard conversation) onOpen;
  final VoidCallback onSeeAll;
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeaderWithLink(title: 'Today so far', linkKey: 'recap-see-all', onTap: onSeeAll),
        if (loading)
          const SectionLoading(key: Key('recap-loading'), label: "Loading today's conversations")
        else if (error != null)
          SectionError(message: error!, retryKey: const Key('recap-retry'), onRetry: onRetry)
        else if (conversations.isEmpty)
          const SectionEmpty(message: 'No conversations yet today.')
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              recapLine(conversations),
              key: const Key('recap-line'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          for (final conversation in conversations.take(maxVisible))
            ConversationCardTile(
              conversation: conversation,
              // Today's page already has the side margins
              padding: const EdgeInsets.symmetric(vertical: 10),
              onTap: () => onOpen(conversation),
            ),
          if (conversations.length > maxVisible)
            Text(
              '+${conversations.length - maxVisible} more today',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.blue),
            ),
        ],
      ],
    );
  }
}

/// "3 conversations · 1 h 5 min · with Ada, Marco".
String recapLine(List<ConversationCard> conversations) {
  final count = conversations.length;
  final total = conversations.fold(Duration.zero, (sum, c) => sum + c.duration);
  final people = <String>[];
  for (final c in conversations) {
    for (final name in c.people) {
      if (!people.contains(name)) people.add(name);
    }
  }
  return [
    count == 1 ? '1 conversation' : '$count conversations',
    if (total.inMinutes > 0) formatDuration(total),
    if (people.isNotEmpty)
      'with ${people.take(3).join(', ')}${people.length > 3 ? ' +${people.length - 3}' : ''}',
  ].join(' · ');
}

/// Tasks due today (or overdue) and the ones created today.
final class TodayTasksSection extends StatelessWidget {
  const TodayTasksSection({
    required this.loading,
    required this.tasks,
    required this.error,
    required this.busy,
    required this.onRetry,
    required this.onToggle,
    required this.onDismiss,
    required this.onSeeAll,
    required this.now,
    this.maxVisible = 5,
    super.key,
  });

  final bool loading;
  final List<TaskItem> tasks;
  final String? error;
  final bool Function(TaskItem task) busy;
  final VoidCallback onRetry;
  final void Function(TaskItem task) onToggle;
  final void Function(TaskItem task) onDismiss;
  final VoidCallback onSeeAll;
  final DateTime now;
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final hidden = tasks.length - maxVisible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeaderWithLink(title: 'Tasks', linkKey: 'tasks-see-all', onTap: onSeeAll),
        if (loading)
          const SectionLoading(key: Key('tasks-loading'), label: 'Loading tasks')
        else if (error != null)
          SectionError(message: error!, retryKey: const Key('tasks-retry'), onRetry: onRetry)
        else if (tasks.isEmpty)
          const SectionEmpty(message: 'Nothing due today.')
        else ...[
          for (final task in tasks.take(maxVisible))
            TaskTile(
              task: task,
              now: now,
              busy: busy(task),
              padding: EdgeInsets.zero,
              onToggle: () => onToggle(task),
              onDismiss: task.done ? null : () => onDismiss(task),
            ),
          if (hidden > 0)
            Text(
              '+$hidden more',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ],
    );
  }
}

/// The digest of the latest finished day, labelled with its day.
final class DigestSection extends StatefulWidget {
  const DigestSection({
    required this.loading,
    required this.summary,
    required this.error,
    required this.onRetry,
    required this.now,
    super.key,
  });

  final bool loading;
  final DailySummary? summary;
  final String? error;
  final VoidCallback onRetry;
  final DateTime now;

  @override
  State<DigestSection> createState() => _DigestSectionState();
}

final class _DigestSectionState extends State<DigestSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final digest = widget.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: digest == null ? 'Daily summary' : dayLabel(digest.date, widget.now),
        ),
        if (widget.loading)
          const SectionLoading(key: Key('summary-loading'), label: 'Loading the daily summary')
        else if (widget.error != null)
          SectionError(
            message: widget.error!,
            retryKey: const Key('summary-retry'),
            onRetry: widget.onRetry,
          )
        else if (digest == null)
          const SectionEmpty(message: 'Echo writes a summary of each day overnight.')
        else
          InkWell(
            key: const Key('summary-content'),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                digest.summary,
                maxLines: _expanded ? null : 4,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
      ],
    );
  }
}

/// The latest weekly summary: what the week was about, its highlights, who came up.
final class WeeklySummarySection extends StatefulWidget {
  const WeeklySummarySection({required this.week, super.key});

  final WeeklySummary week;

  @override
  State<WeeklySummarySection> createState() => _WeeklySummarySectionState();
}

final class _WeeklySummarySectionState extends State<WeeklySummarySection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final week = widget.week;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      key: const Key('weekly-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: 'Week of ${shortDate(week.weekStart)}'),
        InkWell(
          key: const Key('weekly-summary-content'),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  week.summary,
                  maxLines: _expanded ? null : 4,
                  overflow: _expanded ? null : TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
                if (_expanded)
                  for (final highlight in week.highlights)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('• $highlight', style: textTheme.bodyMedium),
                    ),
                if (week.people.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'With ${week.people.take(4).join(', ')}',
                      style: textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _HeaderWithLink extends StatelessWidget {
  const _HeaderWithLink({required this.title, required this.linkKey, required this.onTap});

  final String title;
  final String linkKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: SectionHeader(title: title)),
        TextButton(
          key: Key(linkKey),
          onPressed: onTap,
          // Text flush with the right edge, like the other section headers
          style: TextButton.styleFrom(padding: const EdgeInsets.only(left: 12)),
          child: const Text('See all'),
        ),
      ],
    );
  }
}
