import 'dart:async';

import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../models/segment.dart';
import '../models/task_item.dart';
import '../services/api_exception.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/conversation_card.dart';
import '../utils/formatting.dart';
import '../widgets/memory_entity_row.dart';
import '../widgets/sections.dart';
import '../widgets/task_tile.dart';
import 'navigation.dart';
import 'task_editing.dart';
import 'transcript_detail_screen.dart';

enum _DetailTab { summary, transcript }

/// One conversation: what it was about (summary, tasks, events, people, ideas)
/// and what was said, line by line, each line correctable.
final class ConversationDetailScreen extends StatefulWidget {
  const ConversationDetailScreen({
    required this.conversationId,
    required this.api,
    this.onAsk,
    this.clock = DateTime.now,
    super.key,
  });

  final String conversationId;
  final MemoryApi api;
  final AskCallback? onAsk;
  final DateTime Function() clock;

  @override
  State<ConversationDetailScreen> createState() => _ConversationDetailScreenState();
}

final class _ConversationDetailScreenState extends State<ConversationDetailScreen>
    with TaskEditing {
  @override
  MemoryApi get taskApi => widget.api;

  ConversationDetail? _detail;
  String? _error;
  bool _loading = true;
  bool _deleting = false;
  _DetailTab _tab = _DetailTab.summary;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = _detail == null;
      _error = null;
    });
    try {
      final detail = await widget.api.getConversation(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        resetTaskEdits();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userMessage(error, 'Could not load this conversation.');
      });
    }
  }

  List<TaskItem> get _tasks {
    final detail = _detail;
    if (detail == null) return const [];
    return editedTasks(detail.ofType('task').map(TaskItem.fromEntity));
  }

  Future<void> _openLine(TranscriptLine line) async {
    final api = widget.api;
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TranscriptDetailScreen(
          segment: RecentSegment(
            id: line.segmentId,
            receivedAt: line.recordedAt,
            recordedAt: line.recordedAt,
            durationMs: 0,
            transcriptionStatus: line.status,
            text: line.text,
            speaker: line.speaker,
            conversationId: widget.conversationId,
          ),
          api: api is TranscriptMemoryApi ? api as TranscriptMemoryApi : null,
        ),
      ),
    );
    if (!mounted) return;
    if (deleted == true) {
      Navigator.of(context).pop();
      return;
    }
    await _load();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: const Text(
          'This permanently deletes the conversation, its transcript and what Echo '
          'learned from it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('conversation-delete-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: EchoPalette.of(context).red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await widget.api.deleteConversation(widget.conversationId);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _showMessage(userMessage(error, 'Could not delete the conversation.'));
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (detail != null)
            PopupMenuButton<String>(
              key: const Key('conversation-menu'),
              tooltip: 'More',
              enabled: !_deleting,
              onSelected: (_) => unawaited(_delete()),
              itemBuilder: (context) => [
                PopupMenuItem(
                  key: const Key('conversation-delete'),
                  value: 'delete',
                  child: Text(
                    'Delete conversation',
                    style: TextStyle(color: EchoPalette.of(context).red),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(key: Key('conversation-loading')));
    }
    final detail = _detail;
    if (detail == null) {
      return FullScreenMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load this conversation',
        message: _error ?? '',
        actionKey: const Key('conversation-retry'),
        actionLabel: 'Retry',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('conversation-detail'),
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          _Header(card: detail.card, people: _people(detail), now: widget.clock()),
          if (widget.onAsk case final ask?)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: OutlinedButton.icon(
                key: const Key('conversation-ask'),
                onPressed: () => askFromAnywhere(
                  context,
                  ask,
                  'What did we say in "${conversationTitle(detail.card)}" '
                  '(${dayLabel(detail.card.startedAt, widget.clock())}, '
                  '${formatTime(detail.card.startedAt)}), and what did I agree to do?',
                ),
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Ask about this conversation'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: SegmentedButton<_DetailTab>(
              key: const Key('conversation-tabs'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _DetailTab.summary, label: Text('Summary')),
                ButtonSegment(value: _DetailTab.transcript, label: Text('Transcript')),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) => setState(() => _tab = selection.single),
            ),
          ),
          if (_tab == _DetailTab.summary)
            ..._summary(detail)
          else
            ..._transcript(detail),
        ],
      ),
    );
  }

  List<String> _people(ConversationDetail detail) {
    final names = <String>[];
    for (final person in detail.ofType('person')) {
      if (!names.contains(person.name)) names.add(person.name);
    }
    return names;
  }

  List<Widget> _summary(ConversationDetail detail) {
    final card = detail.card;
    final textTheme = Theme.of(context).textTheme;
    final tasks = _tasks;
    final events = detail.ofType('event');
    final notes = [...detail.ofType('idea'), ...detail.ofType('note')];
    final now = widget.clock();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        child: Text(
          card.summary ??
              (card.isOpen
                  ? 'Echo is still listening. The summary is written a few minutes after '
                      'the conversation ends.'
                  : card.isProcessing
                      ? 'Echo is still processing this conversation.'
                      : 'Too short for a summary. The transcript has everything that was said.'),
          key: const Key('conversation-summary'),
          style: card.summary == null
              ? textTheme.bodyMedium?.copyWith(color: EchoPalette.of(context).text2)
              : textTheme.bodyLarge,
        ),
      ),
      if (tasks.isNotEmpty) ...[
        const _Section(title: 'Tasks'),
        for (final task in tasks)
          TaskTile(
            task: task,
            busy: isTaskBusy(task),
            now: now,
            onToggle: () => unawaited(toggleTask(task)),
            onDismiss: () => unawaited(dismissTask(task)),
          ),
      ],
      if (events.isNotEmpty) ...[
        const _Section(title: 'Events'),
        for (final event in events) MemoryEntityRow(entity: event, now: now),
      ],
      if (notes.isNotEmpty) ...[
        const _Section(title: 'Ideas & notes'),
        for (final note in notes) MemoryEntityRow(entity: note, now: now),
      ],
    ];
  }

  List<Widget> _transcript(ConversationDetail detail) {
    if (detail.lines.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: SectionEmpty(message: 'No transcript yet.'),
        ),
      ];
    }
    return [
      for (final line in detail.lines)
        _LineTile(
          line: line,
          onTap: line.text == null ? null : () => unawaited(_openLine(line)),
        ),
    ];
  }
}

final class _Header extends StatelessWidget {
  const _Header({required this.card, required this.people, required this.now});

  final ConversationCard card;
  final List<String> people;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final end = card.endedAt;
    final range = end == null || card.duration.inSeconds < 60
        ? formatTime(card.startedAt)
        : '${formatTime(card.startedAt)}–${formatTime(end)} · ${formatDuration(card.duration)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConversationEmoji(emoji: card.emoji, size: 52),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(conversationTitle(card), style: textTheme.headlineMedium),
          ),
          const SizedBox(height: 4),
          Text(
            '${dayLabel(card.startedAt, now)} · $range',
            style: textTheme.bodySmall,
          ),
          if (card.isOpen) ...[
            const SizedBox(height: 4),
            Text(
              'Live · still listening',
              style: textTheme.bodySmall?.copyWith(
                color: palette.green,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (people.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final name in people)
                  Chip(
                    avatar: Icon(Icons.person_outline_rounded, size: 16, color: palette.text2),
                    label: Text(name),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: palette.border),
                    backgroundColor: palette.surface,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

final class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: SectionHeader(title: title),
    );
  }
}

final class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, required this.onTap});

  final TranscriptLine line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final text = line.text;
    final speaker = speakerName(line.speaker);
    final body = text != null
        ? cleanTranscript(text)
        : line.isFailed
            ? 'Transcription failed'
            : 'Transcribing…';
    return Semantics(
      button: onTap != null,
      label: '${formatTime(line.recordedAt)}, $speaker: $body',
      excludeSemantics: true,
      child: InkWell(
        key: Key('line-${line.segmentId}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  formatTime(line.recordedAt),
                  style: textTheme.bodySmall?.copyWith(fontSize: 12),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      speaker,
                      style: textTheme.labelSmall?.copyWith(
                        fontSize: 12,
                        color: line.speaker == 'self' ? palette.blue : palette.text2,
                      ),
                    ),
                    Text(
                      body,
                      style: text == null
                          ? textTheme.bodyMedium?.copyWith(
                              color: line.isFailed ? palette.red : palette.text2,
                              fontStyle: FontStyle.italic,
                            )
                          : textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
