import 'dart:async';

import 'package:flutter/material.dart';

import '../models/task_item.dart';
import '../services/api_service.dart';
import '../services/tasks_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/sections.dart';
import '../widgets/task_tile.dart';
import 'conversation_detail_screen.dart';
import 'memories_screen.dart';

/// The Tasks tab: open tasks by due day, done tasks below.
final class TasksScreen extends StatefulWidget {
  const TasksScreen({
    this.api,
    this.controller,
    this.segmentUploadedStream,
    this.openConversation,
    this.clock = DateTime.now,
    super.key,
  });

  final MemoryApi? api;
  final TasksController? controller;
  final Stream<Object?>? segmentUploadedStream;
  final ConversationOpener? openConversation;
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
          builder: (_) => ConversationDetailScreen(conversationId: id, api: _api),
        ),
      );
    }
    if (mounted) await _controller.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final state = _controller.state;
    // A Material, not a ColoredBox: row ink splashes paint on it
    return Material(
      color: palette.background,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text('Tasks', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  if (!state.loading && state.open.isNotEmpty)
                    Text(
                      '${state.open.length} open',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.border),
            Expanded(child: _body(state)),
          ],
        ),
      ),
    );
  }

  Widget _body(TasksState state) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator(key: Key('tasks-loading')));
    }
    if (state.error != null && state.open.isEmpty && state.done.isEmpty) {
      return FullScreenMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load your tasks',
        message: state.error!,
        actionKey: const Key('tasks-retry'),
        actionLabel: 'Retry',
        onAction: _controller.refresh,
        onRefresh: _controller.refresh,
      );
    }
    if (state.open.isEmpty && state.done.isEmpty) {
      return FullScreenMessage(
        icon: Icons.check_circle_outline_rounded,
        title: 'No tasks yet',
        message: 'When you say you will do something, Echo adds it here.',
        onRefresh: _controller.refresh,
      );
    }

    final now = widget.clock();
    final palette = EchoPalette.of(context);
    return RefreshIndicator(
      onRefresh: _controller.refresh,
      child: ListView(
        key: const Key('tasks-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          if (state.open.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: SectionEmpty(message: 'All done. Nothing open right now.'),
            ),
          for (final group in groupTasks(state.open, now)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Semantics(
                header: true,
                child: Text(
                  '${group.bucket.label.toUpperCase()} · ${group.tasks.length}',
                  key: Key('task-group-${group.bucket.name}'),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: 12,
                        letterSpacing: 0.6,
                        color: group.bucket == TaskBucket.overdue ? palette.red : null,
                      ),
                ),
              ),
            ),
            for (final task in group.tasks) _tile(task, state, now),
          ],
          if (state.done.isNotEmpty) ...[
            const SizedBox(height: 8),
            Divider(height: 1, color: palette.border),
            ListTile(
              key: const Key('tasks-done-toggle'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(
                'Done · ${state.done.length}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              trailing: Icon(
                _showDone ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                color: palette.text2,
              ),
              onTap: () => setState(() => _showDone = !_showDone),
            ),
            if (_showDone)
              for (final task in state.done) _tile(task, state, now),
          ],
        ],
      ),
    );
  }

  Widget _tile(TaskItem task, TasksState state, DateTime now) {
    final conversationId = task.conversationId;
    return TaskTile(
      task: task,
      now: now,
      busy: state.busyIds.contains(task.id),
      onToggle: () => unawaited(_toggle(task)),
      onDismiss: task.done ? null : () => unawaited(_dismiss(task)),
      onOpenConversation: conversationId == null
          ? null
          : () => unawaited(_openConversation(conversationId)),
    );
  }
}
