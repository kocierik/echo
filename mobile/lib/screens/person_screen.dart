import 'dart:async';

import 'package:flutter/material.dart';

import '../models/person.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/conversation_card.dart';
import '../utils/formatting.dart';
import '../widgets/memory_entity_row.dart';
import '../widgets/panel.dart';
import '../widgets/person_avatar.dart';
import '../widgets/sections.dart';
import '../widgets/task_tile.dart';
import 'conversation_detail_screen.dart';
import '../utils/calendar_request.dart';
import 'navigation.dart';
import 'task_editing.dart';

/// One person: who they are, what is open with them, and where they came up.
final class PersonScreen extends StatefulWidget {
  const PersonScreen({
    required this.personId,
    required this.api,
    this.onAsk,
    this.clock = DateTime.now,
    super.key,
  });

  final String personId;
  final MemoryApi api;
  final AskCallback? onAsk;
  final DateTime Function() clock;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

final class _PersonScreenState extends State<PersonScreen> with TaskEditing {
  PersonDetail? _detail;
  String? _error;
  bool _loading = true;
  bool _deleting = false;

  @override
  MemoryApi get taskApi => widget.api;

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
      final detail = await widget.api.getPerson(widget.personId);
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
        _error = userMessage(error, 'Could not load this person.');
      });
    }
  }

  Future<void> _openConversation(String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ConversationDetailScreen(
          conversationId: id,
          api: widget.api,
          onAsk: widget.onAsk,
          clock: widget.clock,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _rejectFact(PersonFact fact) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.close_rounded),
          title: const Text('Not true'),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.api.deletePersonFact(widget.personId, fact.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(userMessage(error, 'Could not reject this fact.')),
        ));
      return;
    }
    if (mounted) await _load();
  }

  Widget _facts(PersonDetail detail) {
    const categories = {
      'work': 'Work',
      'family': 'Family',
      'home': 'Home',
      'interests': 'Interests',
      'plans': 'Plans',
      'other': 'Other',
    };
    final facts = List.of(detail.facts)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final earlier = List.of(detail.earlierFacts)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    Widget row(PersonFact fact, {bool superseded = false}) => _FactRow(
          fact: fact,
          superseded: superseded,
          onTap: fact.conversationId == null
              ? null
              : () => unawaited(_openConversation(fact.conversationId!)),
          onLongPress: () => unawaited(_rejectFact(fact)),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: PanelHeader(title: 'What Echo knows'),
        ),
        for (final category in categories.entries)
          if (facts.any((fact) => fact.category == category.key))
            PanelSection(
              title: category.value,
              children: [
                for (final fact in facts.where((fact) => fact.category == category.key))
                  row(fact),
              ],
            ),
        if (earlier.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Panel(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                title: const Text('Before'),
                children: [
                  for (final fact in earlier) row(fact, superseded: true),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// A person Echo got wrong (a misheard word, someone else's name) goes, with what
  /// was said about them; their conversations stay.
  Future<void> _delete() async {
    final name = _detail?.person.name ?? 'this person';
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete $name?'),
            content: const Text(
              'Echo forgets this person. The conversations they came up in stay.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      await widget.api.deleteEntity(widget.personId);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(userMessage(error, 'Could not delete this person.')),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoPalette.of(context).background,
      appBar: AppBar(
        actions: [
          if (_detail != null)
            IconButton(
              key: const Key('person-delete'),
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _deleting ? null : _delete,
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(key: Key('person-loading')));
    }
    final detail = _detail;
    if (detail == null) {
      return FullScreenMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load this person',
        message: _error ?? '',
        actionKey: const Key('person-retry'),
        actionLabel: 'Retry',
        onAction: _load,
      );
    }

    final person = detail.person;
    final now = widget.clock();
    final tasks = editedTasks(detail.tasks);
    final ask = widget.onAsk;
    final nothingLinked =
        tasks.isEmpty && detail.events.isEmpty && detail.conversations.isEmpty;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('person-detail'),
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          _Header(person: person, now: now),
          if (detail.facts.isNotEmpty || detail.earlierFacts.isNotEmpty) _facts(detail),
          if (ask != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: OutlinedButton.icon(
                key: const Key('person-ask'),
                onPressed: () => askFromAnywhere(
                  context,
                  ask,
                  'What did I talk about with ${person.name} recently, '
                  'and what is still open with them?',
                ),
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: Text('Ask about ${person.name}'),
              ),
            ),
          if (tasks.isNotEmpty)
            PanelSection(title: 'Open tasks', trailing: '${tasks.length}', children: [
              for (final task in tasks)
                TaskTile(
                  task: task,
                  now: now,
                  busy: isTaskBusy(task),
                  padding: const EdgeInsets.only(left: 6, right: 4),
                  onToggle: () => unawaited(toggleTask(task)),
                  onDismiss: () => unawaited(dismissTask(task)),
                  onOpenConversation: task.conversationId == null
                      ? null
                      : () => unawaited(_openConversation(task.conversationId!)),
                ),
            ]),
          if (detail.events.isNotEmpty)
            PanelSection(title: 'Events', trailing: '${detail.events.length}', children: [
              for (final event in detail.events)
                MemoryEntityRow(
                  entity: event,
                  now: now,
                  onAddToCalendar: ask == null
                      ? null
                      : () => askFromAnywhere(context, ask, calendarRequest(event)),
                  onTap: event.conversationId == null
                      ? null
                      : () => unawaited(_openConversation(event.conversationId!)),
                ),
            ]),
          if (detail.conversations.isNotEmpty)
            PanelSection(
              title: 'Conversations',
              trailing: '${detail.conversations.length}',
              children: [
                for (final conversation in detail.conversations)
                  ConversationCardTile(
                    conversation: conversation,
                    dayFrom: now,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    onTap: () => unawaited(_openConversation(conversation.id)),
                  ),
              ],
            ),
          if (nothingLinked)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SectionEmpty(
                message: 'Nothing else is linked to ${person.name} yet.',
              ),
            ),
        ],
      ),
    );
  }
}

final class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.fact,
    required this.onTap,
    required this.onLongPress,
    this.superseded = false,
  });

  final PersonFact fact;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;
  final bool superseded;

  String formatDate(DateTime value) {
    final local = value.toLocal();
    return '${shortDate(local)}, ${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: Key('person-fact-${fact.id}'),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fact.text,
              style: textTheme.bodyMedium?.copyWith(
                decoration: superseded ? TextDecoration.lineThrough : null,
              ),
            ),
            const SizedBox(height: 4),
            Text(fact.quote, style: textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(formatDate(fact.createdAt), style: textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// "Seen today", "Seen yesterday", "Seen Mon, Oct 12", or null if never.
String? seenLabel(PersonSummary person, DateTime now) {
  final seen = person.lastSeen;
  if (seen == null) return null;
  final day = dayLabel(seen, now);
  return 'Seen ${day == 'Today' || day == 'Yesterday' ? day.toLowerCase() : day}';
}

final class _Header extends StatelessWidget {
  const _Header({required this.person, required this.now});

  final PersonSummary person;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final subtitle = [
      if (person.role != null) person.role!,
      if (seenLabel(person, now) case final seen?) seen,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PersonAvatar(initials: person.initials, size: 64),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(person.name, style: textTheme.displayLarge?.copyWith(fontSize: 28)),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: textTheme.bodySmall),
          ],
          if (person.about != null) ...[
            const SizedBox(height: 10),
            Text(person.about!, style: textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// A person in a list: avatar, name, role and when they were last seen, and how
/// much is linked to them.
final class PersonTile extends StatelessWidget {
  const PersonTile({required this.person, required this.onTap, required this.now, super.key});

  final PersonSummary person;
  final VoidCallback onTap;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final details = [
      if (person.role != null) person.role!,
      if (seenLabel(person, now) case final seen?) seen,
    ].join(' · ');
    final counts = [
      if (person.conversationCount > 0)
        person.conversationCount == 1
            ? '1 conversation'
            : '${person.conversationCount} conversations',
      if (person.openTaskCount > 0)
        person.openTaskCount == 1 ? '1 open task' : '${person.openTaskCount} open tasks',
    ].join(' · ');
    return Semantics(
      button: true,
      label: [person.name, if (details.isNotEmpty) details, if (counts.isNotEmpty) counts]
          .join('. '),
      excludeSemantics: true,
      child: InkWell(
        key: Key('person-${person.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              PersonAvatar(initials: person.initials),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(person.name, style: textTheme.titleSmall),
                    if (details.isNotEmpty)
                      Text(details, style: textTheme.bodySmall?.copyWith(fontSize: 13)),
                    if (counts.isNotEmpty)
                      Text(
                        counts,
                        style: textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          color: person.openTaskCount > 0 ? palette.accent : null,
                        ),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: palette.text2),
            ],
          ),
        ),
      ),
    );
  }
}
