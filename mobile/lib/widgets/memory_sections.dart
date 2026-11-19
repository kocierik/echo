import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../models/person.dart';
import '../models/today_insights.dart';
import '../services/memory/memories_controller.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'conversation_card.dart';
import 'echo_grouped.dart';
import 'memory_entity_row.dart';
import 'panel.dart';
import 'person_avatar.dart';
import 'sections.dart';
import 'summary_sections.dart';

/// The conversations split by day (local time), keeping their order.
List<List<ConversationCard>> conversationsByDay(List<ConversationCard> conversations) {
  final days = <List<ConversationCard>>[];
  DateTime? current;
  for (final conversation in conversations) {
    final day = dayOf(conversation.startedAt);
    if (day != current) {
      current = day;
      days.add([]);
    }
    days.last.add(conversation);
  }
  return days;
}

/// What a day was mostly about: the title of its longest conversation with one.
String? mainTopic(List<ConversationCard> day) {
  final titled = day.where((c) => c.title != null).toList()
    ..sort((a, b) => b.duration.compareTo(a.duration));
  return titled.isEmpty ? null : titled.first.title;
}

/// Who came up today (seen today), the most talked about first.
List<PersonSummary> peopleSeenOn(List<PersonSummary> people, DateTime now) {
  final today = dayOf(now);
  return people.where((p) => p.lastSeen != null && dayOf(p.lastSeen!) == today).toList()
    ..sort((a, b) => b.conversationCount.compareTo(a.conversationCount));
}

/// Search over the whole memory: conversations, people, tasks.
final class MemorySearchField extends StatelessWidget {
  const MemorySearchField({
    required this.controller,
    required this.searching,
    required this.onChanged,
    required this.onClear,
    this.hint = 'Search conversations, people, tasks',
    this.autofocus = false,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final bool searching;
  final ValueChanged<String> onChanged;

  /// The keyboard opens with it (the search screen).
  final bool autofocus;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return TextField(
          key: const Key('memories-search'),
          autofocus: autofocus,
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            prefixIcon: const Icon(CupertinoIcons.search, size: 20),
            suffixIcon: value.text.isEmpty
                ? null
                : searching
                    ? const Padding(
                        key: Key('memories-searching'),
                        padding: EdgeInsets.all(14),
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        key: const Key('memories-search-clear'),
                        tooltip: 'Clear search',
                        onPressed: onClear,
                        icon: const Icon(CupertinoIcons.xmark, size: 20),
                      ),
          ),
        );
      },
    );
  }
}

/// What the search found, or why there is nothing: in place of Today's sections.
final class MemorySearchView extends StatelessWidget {
  const MemorySearchView({
    required this.state,
    required this.now,
    required this.onOpen,
    required this.onRetry,
    this.bottom = 0,
    super.key,
  });

  final MemoriesState state;
  final DateTime now;
  final ValueChanged<String> onOpen;
  final Future<void> Function() onRetry;

  /// Kept free at the bottom (the floating navigation).
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final results = state.results;
    if (state.searchError != null) {
      return FullScreenMessage(
        icon: CupertinoIcons.wifi_slash,
        title: 'Search failed',
        message: state.searchError!,
        actionKey: const Key('search-retry'),
        actionLabel: 'Retry',
        onAction: onRetry,
      );
    }
    if (results == null) {
      return const Center(child: CircularProgressIndicator(key: Key('search-loading')));
    }
    if (results.isEmpty) {
      return FullScreenMessage(
        icon: CupertinoIcons.search,
        title: 'No results',
        message: 'Nothing in your memory matches "${state.query}".',
      );
    }
    return ListView(
      key: const Key('search-results'),
      padding: EdgeInsets.only(top: 4, bottom: 16 + bottom),
      children: [
        if (results.conversations.isNotEmpty)
          PanelSection(
            title: 'Conversations',
            trailing: '${results.conversations.length}',
            children: [
              for (final conversation in results.conversations)
                ConversationCardTile(
                  conversation: conversation,
                  dayFrom: now,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  onTap: () => onOpen(conversation.id),
                ),
            ],
          ),
        if (results.entities.isNotEmpty)
          PanelSection(
            title: 'Mentions',
            trailing: '${results.entities.length}',
            children: [
              for (final entity in results.entities)
                MemoryEntityRow(
                  entity: entity,
                  onTap: entity.conversationId == null
                      ? null
                      : () => onOpen(entity.conversationId!),
                ),
            ],
          ),
      ],
    );
  }
}

/// "People today": who came up today, and the way to everyone.
final class PeoplePanel extends StatelessWidget {
  const PeoplePanel({
    required this.people,
    required this.onOpen,
    required this.onAll,
    this.title = 'People today',
    super.key,
  });

  final String title;
  final List<PersonSummary> people;
  final ValueChanged<String> onOpen;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final shown = people.take(4).toList();
    return Panel(
      key: const Key('people-panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            title: title,
            actionLabel: 'All',
            onAction: onAll,
            actionKey: const Key('people-all'),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final person in shown)
                Expanded(
                  child: Semantics(
                    button: true,
                    label: person.name,
                    excludeSemantics: true,
                    child: InkWell(
                      key: Key('person-${person.id}'),
                      borderRadius: BorderRadius.circular(AppTheme.tileRadius),
                      onTap: () => onOpen(person.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            PersonAvatar(initials: person.initials, size: 52),
                            const SizedBox(height: 6),
                            Text(
                              person.name.split(' ').first,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Four places, so two people do not spread across the panel
              for (var i = shown.length; i < 4; i++) const Expanded(child: SizedBox()),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Earlier": the week's summary first, then each past day with its count and main
/// topic; a tap opens it. More days load at the end.
final class EarlierPanel extends StatelessWidget {
  const EarlierPanel({
    required this.days,
    required this.now,
    required this.onOpenDay,
    this.week,
    this.onOpenWeek,
    this.hasMore = false,
    this.loadingMore = false,
    this.onMore,
    super.key,
  });

  /// Past days, newest first, each with its conversations.
  final List<List<ConversationCard>> days;
  final DateTime now;
  final WeeklySummary? week;
  final VoidCallback? onOpenWeek;
  final void Function(List<ConversationCard> day) onOpenDay;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      if (week case final week?)
        _EarlierRow(
          key: const Key('earlier-week'),
          title: weekLabel(week.weekStart, now),
          subtitle: week.summary,
          onTap: onOpenWeek,
        ),
      for (final day in days)
        _EarlierRow(
          key: Key('earlier-${dayOf(day.first.startedAt).toIso8601String().substring(0, 10)}'),
          title: dayLabel(day.first.startedAt, now),
          subtitle: [
            day.length == 1 ? '1 conversation' : '${day.length} conversations',
            if (mainTopic(day) case final topic?) topic,
          ].join(' · '),
          onTap: () => onOpenDay(day),
        ),
    ];
    return EchoGroup(
      key: const Key('earlier'),
      children: [
        ...rows,
        if (hasMore)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('earlier-more'),
              onPressed: loadingMore ? null : onMore,
              style: TextButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16)),
              child: Text(loadingMore ? 'Loading…' : 'More days'),
            ),
          ),
      ],
    );
  }
}

final class _EarlierRow extends StatelessWidget {
  const _EarlierRow({required this.title, required this.subtitle, this.onTap, super.key});

  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Icon(CupertinoIcons.chevron_right, size: 16, color: palette.text2),
            ],
          ),
        ),
      ),
    );
  }
}

/// A day's conversations in one panel, a row each.
final class DayConversationsPanel extends StatelessWidget {
  const DayConversationsPanel({required this.conversations, required this.onOpen, super.key});

  final List<ConversationCard> conversations;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return EchoGroup(
      children: [
        for (final conversation in conversations)
          ConversationRow(
            conversation: conversation,
            onTap: () => onOpen(conversation.id),
          ),
      ],
    );
  }
}
