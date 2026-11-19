import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/action_models.dart';
import '../models/photo.dart';
import '../models/plan.dart';
import '../models/device_status.dart';
import '../models/memory.dart';
import '../models/task_item.dart';
import '../models/today_insights.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'action_card.dart';
import 'conversation_card.dart';
import 'device_readings.dart';
import 'echo_grouped.dart';
import 'panel.dart';
import 'photo_thumbnail.dart';
import 'sections.dart';
import 'task_tile.dart';

/// Tasks for Today: overdue and due today first, then the ones created today
/// (so a misheard one can be dropped while it is fresh).
List<TaskItem> todayTasks(List<TaskItem> open, DateTime now) {
  // Promises are added by [todayTodo]
  open = open.where((t) => !t.isPromise).toList();
  final today = dayOf(now);
  bool due(TaskItem t) => t.dueDate != null && !dayOf(t.dueDate!).isAfter(today);
  bool createdToday(TaskItem t) => t.createdAt != null && dayOf(t.createdAt!) == today;
  final dueTasks = open.where(due).toList()
    ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
  final fresh = open.where((t) => !due(t) && createdToday(t)).toList();
  return [...dueTasks, ...fresh];
}

/// A promise without a date this old is not kept yet: it goes to the top.
const stalePromise = Duration(days: 3);

/// Open promises: the stale ones without a date first, then by due date, then the rest.
List<TaskItem> openPromises(List<TaskItem> open, DateTime now) {
  bool stale(TaskItem t) =>
      t.dueDate == null && t.createdAt != null && now.difference(t.createdAt!) > stalePromise;
  final promises = open.where((t) => t.isPromise && !t.done).toList();
  final old = promises.where(stale).toList();
  final dated = promises.where((t) => t.dueDate != null).toList()
    ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
  final rest = promises.where((t) => t.dueDate == null && !stale(t)).toList();
  return [...old, ...dated, ...rest];
}

/// "To do today": the promises that are due, waiting too long or made today,
/// then today's tasks. The other promises wait on the Tasks page.
List<TaskItem> todayTodo(List<TaskItem> open, DateTime now) {
  final today = dayOf(now);
  bool forToday(TaskItem t) {
    final due = t.dueDate;
    if (due != null) return !dayOf(due).isAfter(today);
    final created = t.createdAt;
    return created != null &&
        (dayOf(created) == today || now.difference(created) > stalePromise);
  }

  return [...openPromises(open, now).where(forToday), ...todayTasks(open, now)];
}

/// Today's conversations (and one still going), newest first.
List<ConversationCard> todayConversations(List<ConversationCard> all, DateTime now) {
  final today = dayOf(now);
  return all.where((c) => c.isOpen || dayOf(c.startedAt) == today).toList();
}

/// "3 conversations, 1 h 5 min".
String dayTotals(List<ConversationCard> conversations) {
  final count = conversations.length;
  final total = conversations.fold(Duration.zero, (sum, c) => sum + c.duration);
  return [
    count == 1 ? '1 conversation' : '$count conversations',
    if (total.inMinutes > 0) formatDuration(total),
  ].join(', ');
}

/// "With Ada, Marco, Luca +2" (null when nobody was named).
String? peopleLine(List<ConversationCard> conversations) {
  final people = <String>[];
  for (final c in conversations) {
    for (final name in c.people) {
      if (!people.contains(name)) people.add(name);
    }
  }
  if (people.isEmpty) return null;
  final more = people.length > 3 ? ' +${people.length - 3}' : '';
  return 'With ${people.take(3).join(', ')}$more';
}

/// What is wrong with the wearable, and the way to fix it. Nothing while it
/// works: the pill in the header says how it is.
final class DeviceProblemPanel extends StatelessWidget {
  const DeviceProblemPanel({
    required this.state,
    this.pendingBytes = 0,
    this.onAction,
    this.busy = false,
    this.error,
    super.key,
  });

  final DeviceConnectionState state;

  /// Speech still on the wearable.
  final int pendingBytes;
  final VoidCallback? onAction;
  final bool busy;
  final String? error;

  static bool shows(DeviceConnectionState state) => switch (state) {
        DeviceConnectionState.offline ||
        DeviceConnectionState.error ||
        DeviceConnectionState.bluetoothOff ||
        DeviceConnectionState.unpaired =>
          true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    final (title, body, action) = switch (state) {
      DeviceConnectionState.unpaired => (
          'No Echo paired',
          'Pair your Echo and it starts remembering your day.',
          'Pair Echo',
        ),
      DeviceConnectionState.bluetoothOff => (
          'Bluetooth is off',
          'Turn it on in Control Center to reach Echo.',
          null,
        ),
      _ => (
          'Echo is offline',
          'What it hears stays on Echo and arrives when it reconnects.',
          'Reconnect Echo',
        ),
    };
    if (!shows(state)) return const SizedBox.shrink();
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final waiting = pendingSpeechLabel(pendingBytes);
    return Panel(
      key: const Key('device-problem'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(title, style: textTheme.titleMedium),
          ),
          const SizedBox(height: 4),
          Text(body, style: textTheme.bodyMedium?.copyWith(color: palette.text2)),
          if (waiting != null) ...[
            const SizedBox(height: 4),
            Text(waiting, style: textTheme.bodySmall),
          ],
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: textTheme.bodyMedium?.copyWith(color: palette.red)),
          ],
          if (action != null && onAction != null) ...[
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('device-action'),
              onPressed: busy ? null : onAction,
              child: Text(action),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Needs you": an orange panel per action waiting for a Confirm.
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
        for (final action in actions)
          _NeedsYouPanel(
            action: action,
            busy: busyIds.contains(action.id),
            onConfirm: () => onConfirm(action),
            onCancel: () => onCancel(action),
          ),
      ],
    );
  }
}

final class _NeedsYouPanel extends StatelessWidget {
  const _NeedsYouPanel({
    required this.action,
    required this.busy,
    required this.onConfirm,
    required this.onCancel,
  });

  final PendingAction action;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  bool get _pending => action.status == null || action.status == 'pending';

  /// "Gmail, asked by voice".
  String? get _caption {
    final parts = [
      if (action.app case final app?) app,
      if (action.source == 'voice') 'asked by voice',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final label = ActionCard.statusLabel(action.status);
    return EchoGroup(
      key: Key('action-card-${action.id}'),
      header: 'Needs you',
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                action.summary,
                style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (_caption case final caption?) ...[
                const SizedBox(height: 3),
                Text(caption, style: textTheme.bodySmall?.copyWith(color: palette.text2)),
              ],
              const SizedBox(height: 12),
              if (_pending)
                // Wraps on narrow screens with large text instead of overflowing
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _DoneChip(
                      key: Key('action-confirm-${action.id}'),
                      onTap: busy
                          ? null
                          : () {
                              HapticFeedback.lightImpact();
                              onConfirm();
                            },
                    ),
                    TextButton(
                      key: Key('action-cancel-${action.id}'),
                      onPressed: busy ? null : onCancel,
                      style: TextButton.styleFrom(
                        foregroundColor: palette.text2,
                        minimumSize: const Size(44, 44),
                      ),
                      child: const Text('Cancel'),
                    ),
                    if (busy)
                      SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: palette.accent),
                      ),
                  ],
                )
              else if (label != null)
                Text(
                  label,
                  key: Key('action-status-${action.id}'),
                  style: textTheme.labelLarge?.copyWith(
                    color: switch (action.status) {
                      'executed' => palette.green,
                      'failed' => palette.red,
                      'unknown' => palette.amber,
                      _ => palette.text2,
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The accent chip that confirms an action: 44 pt tall.
final class _DoneChip extends StatelessWidget {
  const _DoneChip({required this.onTap, super.key});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Semantics(
      button: true,
      enabled: onTap != null,
      excludeSemantics: true,
      label: 'Done',
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.5 : 1,
          child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.accent,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text(
                'Done',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.onAccent, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// "To do today": a few tasks with their checkboxes, the rest on the Tasks page.
final class TodoPanel extends StatelessWidget {
  const TodoPanel({
    required this.loading,
    required this.tasks,
    required this.error,
    required this.busy,
    required this.onRetry,
    required this.onToggle,
    required this.onDismiss,
    required this.onSeeAll,
    required this.now,
    this.maxVisible = 3,
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
    final textTheme = Theme.of(context).textTheme;
    return EchoGroup(
      key: const Key('todo-panel'),
      header: 'To do today',
      children: [
        if (loading)
          const _Inset(child: SectionLoading(key: Key('tasks-loading'), label: 'Loading tasks'))
        else if (error != null)
          _Inset(
            child: SectionError(
              message: error!,
              retryKey: const Key('tasks-retry'),
              onRetry: onRetry,
            ),
          )
        else if (tasks.isEmpty)
          const _Inset(child: SectionEmpty(message: 'Nothing due today.'))
        else ...[
          for (final task in tasks.take(maxVisible))
            TaskTile(
              task: task,
              now: now,
              busy: busy(task),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              showSource: false,
              onToggle: () => onToggle(task),
              onDismiss: task.done ? null : () => onDismiss(task),
            ),
          if (hidden > 0)
            _Inset(
              child: Text(
                hidden == 1 ? '1 more in Tasks' : '$hidden more in Tasks',
                key: const Key('tasks-more'),
                style: textTheme.bodySmall,
              ),
            ),
        ],
        _SeeAllRow(actionKey: const Key('tasks-see-all'), label: 'See all', onTap: onSeeAll),
      ],
    );
  }
}

/// The last row of a group: an accent link, a 44 pt target.
final class _SeeAllRow extends StatelessWidget {
  const _SeeAllRow({required this.label, required this.onTap, this.actionKey});

  final String label;
  final VoidCallback onTap;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return InkWell(
      key: actionKey,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(label, style: TextStyle(color: palette.accent, fontSize: 15)),
          ),
        ),
      ),
    );
  }
}

final class _Inset extends StatelessWidget {
  const _Inset({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: child);
}

/// "Your day": the totals, who was there, and today's conversations on a
/// timeline, ending with the one still being recorded.
final class YourDayPanel extends StatelessWidget {
  const YourDayPanel({
    required this.loading,
    required this.conversations,
    required this.error,
    required this.recording,
    required this.onRetry,
    required this.onOpen,
    required this.onSeeAll,
    this.maxVisible = 4,
    this.loadPhoto,
    this.now,
    this.liveLines = const [],
    super.key,
  });

  final bool loading;

  /// For how long the conversation going on has lasted.
  final DateTime? now;

  /// The last lines heard in the conversation going on, (who, what), oldest first.
  final List<(String, String)> liveLines;

  /// The image of a photo row (no thumbnail without it).
  final PhotoSourceLoader? loadPhoto;

  /// Today's conversations, newest first.
  final List<ConversationCard> conversations;
  final String? error;

  /// The wearable is listening right now.
  final bool recording;
  final VoidCallback onRetry;
  final void Function(ConversationCard conversation) onOpen;
  final VoidCallback onSeeAll;

  /// Finished conversations shown: the latest ones.
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final finished = conversations.where((c) => !c.isOpen).toList().reversed.toList();
    final open = conversations.where((c) => c.isOpen).toList();
    final earlier = finished.length - maxVisible;
    final visible = earlier > 0 ? finished.sublist(earlier) : finished;
    final people = peopleLine(conversations);
    final ready = !loading && error == null && conversations.isNotEmpty;
    return EchoGroup(
      key: const Key('your-day'),
      header: 'Your day',
      children: [
        if (ready)
          _Inset(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dayTotals(conversations), style: textTheme.bodySmall),
                if (people != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      people,
                      key: const Key('recap-line'),
                      style: textTheme.bodyMedium?.copyWith(color: palette.text2),
                    ),
                  ),
              ],
            ),
          ),
        if (loading)
          const _Inset(
              child: SectionLoading(key: Key('recap-loading'), label: "Loading today's conversations"))
        else if (error != null)
          _Inset(
              child: SectionError(
                  message: error!, retryKey: const Key('recap-retry'), onRetry: onRetry))
        else if (conversations.isEmpty)
          const _Inset(child: SectionEmpty(message: 'No conversations yet today.'))
        else ...[
          if (earlier > 0)
            _Inset(
              child: Text(
                earlier == 1 ? '1 earlier today' : '$earlier earlier today',
                style: textTheme.bodySmall,
              ),
            ),
          for (final conversation in visible)
            _Inset(
              child: _TimelineRow(
                label: formatTime(conversation.startedAt),
                child: conversation.isPhoto && loadPhoto != null
                    ? _PhotoBlock(
                        conversation: conversation,
                        loadPhoto: loadPhoto!,
                        onTap: () => onOpen(conversation),
                      )
                    : _ConversationBlock(
                        conversation: conversation,
                        onTap: () => onOpen(conversation),
                      ),
              ),
            ),
          for (final conversation in open)
            _Inset(
              child: _NowRow(
                conversation: conversation,
                recording: recording,
                now: now,
                liveLines: liveLines,
                onTap: () => onOpen(conversation),
              ),
            ),
        ],
        _SeeAllRow(
            actionKey: const Key('recap-see-all'), label: 'See the whole day', onTap: onSeeAll),
      ],
    );
  }
}

/// A time on the left, its conversation on the right.
final class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 46,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              label,
              style: textTheme.labelSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(child: child),
      ],
    );
  }
}

/// A conversation as a block on the timeline: blue when it left something to
/// do, a single line when it was short and with nobody in particular.
final class _ConversationBlock extends StatelessWidget {
  const _ConversationBlock({required this.conversation, required this.onTap});

  final ConversationCard conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final c = conversation;
    final title = conversationTitle(c);
    final duration = c.duration.inMinutes > 0 ? formatDuration(c.duration) : null;
    final place = c.place?.label;
    final brief = c.people.isEmpty &&
        c.taskCount == 0 &&
        place == null &&
        c.duration < const Duration(minutes: 10);
    final marked = c.taskCount > 0;
    final color = brief
        ? palette.surface2
        : marked
            ? palette.accentSoft
            : palette.tint;
    final muted = marked ? palette.onAccentSoft : palette.text2;
    final meta = [
      if (c.people.isNotEmpty) c.people.take(2).join(', '),
      // Where it happened, when Places visited is on: "Cena con Marco — Trattoria da Mario"
      if (place != null) place,
      if (duration != null) duration,
    ];
    final radius = BorderRadius.circular(AppTheme.tileRadius);
    return Semantics(
      button: true,
      label: [title, ...meta].join(', '),
      excludeSemantics: true,
      child: Material(
        color: color,
        borderRadius: radius,
        child: InkWell(
          key: Key('day-${c.id}'),
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: brief
                ? Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall,
                        ),
                      ),
                      if (duration != null) ...[
                        const SizedBox(width: 8),
                        Text(duration, style: textTheme.bodySmall?.copyWith(color: muted)),
                      ],
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall,
                      ),
                      if (c.summary case final summary?) ...[
                        const SizedBox(height: 2),
                        Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(color: muted),
                        ),
                      ],
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          meta.join('   '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(color: muted),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A photo on its own in the day: its thumbnail, "Photo: <title>" and what it showed.
final class _PhotoBlock extends StatelessWidget {
  const _PhotoBlock({required this.conversation, required this.loadPhoto, required this.onTap});

  final ConversationCard conversation;
  final PhotoSourceLoader loadPhoto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final c = conversation;
    final title = c.title == null ? 'Photo' : 'Photo: ${c.title}';
    final radius = BorderRadius.circular(AppTheme.tileRadius);
    return Semantics(
      button: true,
      label: [title, if (c.summary != null) c.summary!].join(', '),
      excludeSemantics: true,
      child: Material(
        color: palette.tint,
        borderRadius: radius,
        child: InkWell(
          key: Key('day-${c.id}'),
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox.square(
                    dimension: 48,
                    child: FutureBuilder<PhotoImageSource>(
                      future: loadPhoto(c.photoId!),
                      builder: (context, snapshot) {
                        final source = snapshot.data;
                        if (source == null) return ColoredBox(color: palette.surface2);
                        return Image.network(
                          source.url.toString(),
                          key: Key('day-photo-${c.photoId}'),
                          headers: source.headers,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              ColoredBox(color: palette.surface2),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall,
                      ),
                      if (c.summary case final summary?) ...[
                        const SizedBox(height: 2),
                        Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(color: palette.text2),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Now ——— Recording": the conversation still going.
/// The conversation going on: for how long, who is there, its title and the last line
/// heard (what Today's card on top used to show).
final class _NowRow extends StatelessWidget {
  const _NowRow({
    required this.conversation,
    required this.recording,
    required this.now,
    required this.liveLines,
    required this.onTap,
  });

  final ConversationCard conversation;
  final bool recording;
  final DateTime? now;
  final List<(String, String)> liveLines;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final style = textTheme.labelSmall?.copyWith(
      color: palette.accent,
      fontWeight: FontWeight.w600,
    );
    final label = recording ? 'Recording' : 'In progress';
    final going = now?.difference(conversation.startedAt);
    final title = conversation.title;
    final people = conversation.people;
    return Semantics(
      button: true,
      label: 'Conversation going on now, ${label.toLowerCase()}',
      child: InkWell(
        key: const Key('day-now'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    going != null && going.inMinutes > 0
                        ? 'Now · ${formatDuration(going)}'
                        : 'Now',
                    style: style,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Container(height: 2, color: palette.accent)),
                  const SizedBox(width: 8),
                  Text(label, style: style),
                ],
              ),
              if (title != null) ...[
                const SizedBox(height: 4),
                Text(title, style: textTheme.titleSmall),
              ],
              if (people.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('with ${people.join(', ')}', style: textTheme.bodySmall),
              ],
              // The live transcript: the last lines, one each, who said it first
              if (liveLines.isNotEmpty) const SizedBox(height: 4),
              for (final (i, (who, what)) in liveLines.indexed)
                Text.rich(
                  key: Key('day-now-line-$i'),
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$who  ',
                        style: textTheme.labelSmall?.copyWith(color: palette.text2),
                      ),
                      TextSpan(text: what),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Echo is working on it": voice requests and photos until their answer arrives.
final class WorkingSection extends StatelessWidget {
  const WorkingSection({required this.items, this.onOpen, super.key});

  final List<WorkingItem> items;
  final void Function(WorkingItem item)? onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      key: const Key('working-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Panel(
              key: Key('working-${item.key}'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              onTap: onOpen == null ? null : () => onOpen!(item),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: palette.accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      workingLabel(item),
                      style: textTheme.bodyMedium,
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

/// "📷 Taking a photo: che pianta è?" / "Working on: che impegni ho domani?".
String workingLabel(WorkingItem item) {
  if (item.isPhoto) {
    return item.text.isEmpty ? '📷 Taking a photo…' : '📷 Taking a photo: ${item.text}';
  }
  return 'Working on: ${item.text}';
}

/// Today's quiet line about the speech budget: before it runs out (four fifths used) and
/// once it is used, what Echo does until it starts again. Nothing otherwise.
final class PlanLine extends StatelessWidget {
  const PlanLine({required this.plan, required this.onOpen, super.key});

  final PlanInfo plan;
  final VoidCallback onOpen;

  static bool shows(PlanInfo? plan) => plan != null && (plan.overBudget || plan.nearBudget);

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final text = plan.overBudget
        ? 'Echo is transcribing ${plan.dailyAllowance} a day until '
            '${dayAndMonth(plan.resetsOn)}.'
        : '${speechAmount(plan.usedSeconds)} of this month\'s '
            '${speechAmount(plan.monthlySeconds)} of speech used.';
    return InkWell(
      key: const Key('plan-line'),
      borderRadius: BorderRadius.circular(8),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.data_usage_rounded, size: 16, color: palette.text2),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
