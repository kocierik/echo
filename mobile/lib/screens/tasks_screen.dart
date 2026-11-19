import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../models/task_item.dart';
import '../services/api/api_service.dart';
import '../services/memory/tasks_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/echo_grouped.dart';
import '../widgets/echo_large_title.dart';
import '../widgets/sections.dart';
import '../widgets/task_tile.dart';
import 'conversation_detail_screen.dart';
import 'navigation.dart';

/// The Tasks tab: open tasks by due day, done tasks below.
final class TasksScreen extends StatefulWidget {
  const TasksScreen({
    this.api,
    this.controller,
    this.segmentUploadedStream,
    this.openConversation,
    this.onAsk,
    this.clock = DateTime.now,
    super.key,
  });

  final MemoryApi? api;
  final TasksController? controller;
  final Stream<Object?>? segmentUploadedStream;
  final ConversationOpener? openConversation;
  final AskCallback? onAsk;
  final DateTime Function() clock;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

final class _TasksScreenState extends State<TasksScreen> {
  late final TasksController _controller;
  late final bool _ownsController;
  late final MemoryApi _api;
  ApiService? _ownedApi;
  bool _showDone = false;

  @override
  void initState() {
    super.initState();
    final api = widget.api ?? (_ownedApi = ApiService());
    _api = api;
    final injected = widget.controller;
    _ownsController = injected == null;
    _controller = injected ??
        TasksController(api: api, uploadStream: widget.segmentUploadedStream);
    _controller.addListener(_onChanged);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
    _ownedApi?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final error = _controller.state.actionError;
    if (error != null) {
      _controller.clearActionError();
      _snack(error);
    }
    setState(() {});
  }

  void _snack(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _toggle(TaskItem task) async {
    final completing = !task.done;
    await _controller.setDone(task, completing);
    if (!mounted || !completing || _controller.state.busyIds.contains(task.id)) return;
    if (_controller.state.done.any((t) => t.id == task.id)) {
      _snack(
        'Done: ${task.name}',
        action: SnackBarAction(
          key: const Key('task-undo'),
          label: 'Undo',
          onPressed: () => unawaited(
            _controller.setDone(task.copyWithDone(true), false),
          ),
        ),
      );
    }
  }

  Future<void> _dismiss(TaskItem task) async {
    await _controller.dismiss(task);
    // A failure puts the task back (and the listener shows why)
    final stillThere = _controller.state.open.any((t) => t.id == task.id);
    if (mounted && !stillThere) _snack('Removed "${task.name}" from your tasks.');
  }

  Future<void> _openConversation(String id) async {
    final opener = widget.openConversation;
    if (opener != null) {
      await opener(context, id);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ConversationDetailScreen(
            conversationId: id,
            api: _api,
            onAsk: widget.onAsk,
            clock: widget.clock,
          ),
        ),
      );
    }
    if (mounted) await _controller.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final state = _controller.state;
    return EchoLargeTitlePage(
      title: 'To do',
      onRefresh: _controller.refresh,
      slivers: [
        if (!state.loading && state.open.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '${state.open.length} open',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text2),
              ),
            ),
          ),
        ..._body(state, palette),
      ],
    );
  }

  List<Widget> _body(TasksState state, EchoPalette palette) {
    if (state.loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator(key: Key('tasks-loading'))),
        ),
      ];
    }
    if (state.error != null && state.open.isEmpty && state.done.isEmpty) {
      return [
        FullScreenMessage(
          sliver: true,
          icon: CupertinoIcons.cloud_bolt,
          title: 'Could not load your tasks',
          message: state.error!,
          actionKey: const Key('tasks-retry'),
          actionLabel: 'Retry',
          onAction: _controller.refresh,
        ),
      ];
    }
    if (state.open.isEmpty && state.done.isEmpty) {
      return [
        const FullScreenMessage(
          sliver: true,
          icon: CupertinoIcons.check_mark_circled,
          title: 'No tasks yet',
          message: 'When you say you will do something, Echo adds it here.',
        ),
      ];
    }

    final now = widget.clock();
    return [
      SliverList.list(
        key: const Key('tasks-list'),
        children: [
          if (state.open.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: SectionEmpty(message: 'All done. Nothing open right now.'),
            ),
          // A group per bucket: overdue, today, this week, later, no date
          for (final group in groupTasks(state.open, now))
            EchoGroup(
              key: Key('task-group-${group.bucket.name}'),
              header: '${group.bucket.label} · ${group.tasks.length}',
              headerColor: group.bucket == TaskBucket.overdue ? palette.red : null,
              children: [for (final task in group.tasks) _tile(task, state, now)],
            ),
          if (state.done.isNotEmpty)
            EchoGroup(
              children: [
                InkWell(
                  key: const Key('tasks-done-toggle'),
                  onTap: () => setState(() => _showDone = !_showDone),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Done · ${state.done.length}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          Icon(
                            _showDone ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                            size: 18,
                            color: palette.text2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_showDone)
                  for (final task in state.done) _tile(task, state, now),
              ],
            ),
        ],
      ),
    ];
  }

  Widget _tile(TaskItem task, TasksState state, DateTime now) {
    final conversationId = task.conversationId;
    return TaskTile(
      task: task,
      now: now,
      padding: const EdgeInsets.only(left: 6, right: 4),
      busy: state.busyIds.contains(task.id),
      onToggle: () => unawaited(_toggle(task)),
      onDismiss: task.done ? null : () => unawaited(_dismiss(task)),
      onOpenConversation: conversationId == null
          ? null
          : () => unawaited(_openConversation(conversationId)),
    );
  }
}

/// Tasks as a page of Today: from "See all" or a promises notification.
final class TasksPage extends StatelessWidget {
  const TasksPage({this.segmentUploadedStream, this.onAsk, super.key});

  final Stream<Object?>? segmentUploadedStream;
  final AskCallback? onAsk;

  @override
  Widget build(BuildContext context) {
    return TasksScreen(segmentUploadedStream: segmentUploadedStream, onAsk: onAsk);
  }
}
