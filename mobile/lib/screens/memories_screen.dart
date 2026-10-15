import 'dart:async';

import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../models/person.dart';
import '../models/today_insights.dart';
import '../services/api/api_service.dart';
import '../services/memory/memories_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/conversation_card.dart';
import '../widgets/echo_nav_bar.dart';
import '../widgets/screen_header.dart';
import '../utils/formatting.dart';
import '../widgets/memory_entity_row.dart';
import '../widgets/panel.dart';
import '../widgets/person_avatar.dart';
import '../widgets/sections.dart';
import '../widgets/summary_sections.dart';
import 'conversation_detail_screen.dart';
import 'navigation.dart';
import 'people_screen.dart';
import 'person_screen.dart';

/// The Memories tab: search across the memory, the latest week and day, the
/// people Echo heard about, and every conversation by day.
final class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({
    this.api,
    this.controller,
    this.segmentUploadedStream,
    this.openConversation,
    this.openPerson,
    this.onAsk,
    this.headerAction,
    this.clock = DateTime.now,
    super.key,
  });

  /// The device pill, in the top right.
  final Widget? headerAction;

  final MemoryApi? api;
  final MemoriesController? controller;
  final Stream<Object?>? segmentUploadedStream;
  final ConversationOpener? openConversation;

  /// Opens a person; returns once their page is closed.
  final ConversationOpener? openPerson;
  final AskCallback? onAsk;
  final DateTime Function() clock;

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

final class _MemoriesScreenState extends State<MemoriesScreen> {
  late final MemoriesController _controller;
  late final bool _ownsController;
  late final MemoryApi _api;
  ApiService? _ownedApi;
  final _searchController = TextEditingController();

  /// The latest daily and weekly summaries, above the conversations.
  DailySummary? _digest;
  WeeklySummary? _week;

  @override
  void initState() {
    super.initState();
    final api = widget.api ?? (_ownedApi = ApiService());
    _api = api;
    final injected = widget.controller;
    _ownsController = injected == null;
    _controller = injected ??
        MemoriesController(api: api, uploadStream: widget.segmentUploadedStream);
    _controller.addListener(_onChanged);
    unawaited(_controller.initialize());
    unawaited(_controller.loadPeople());
    unawaited(_loadSummaries());
  }

  /// Optional: without them (or on a failure) the list starts with the days.
  Future<void> _loadSummaries() async {
    final api = _api;
    if (api is TodayApi) {
      try {
        final digest = await api.getLatestDigest();
        if (mounted) setState(() => _digest = digest);
      } catch (_) {}
    }
    if (api case final WeeklySummaryApi weekly) {
      try {
        final week = await weekly.getLatestWeeklySummary();
        if (mounted) setState(() => _week = week);
      } catch (_) {}
    }
  }

  Future<void> _refresh() async {
    await Future.wait([_controller.refresh(), _controller.loadPeople(), _loadSummaries()]);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
    _ownedApi?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _open(String id) async {
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

  Future<void> _openPerson(String id) async {
    final opener = widget.openPerson;
    if (opener != null) {
      await opener(context, id);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PersonScreen(
            personId: id,
            api: _api,
            onAsk: widget.onAsk,
            clock: widget.clock,
          ),
        ),
      );
    }
    if (mounted) await _controller.loadPeople();
  }

  Future<void> _openPeople() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => PeopleScreen(
        controller: _controller,
        onOpenPerson: _openPerson,
        now: widget.clock(),
      ),
    ));
  }

  void _clearSearch() {
    _searchController.clear();
    _controller.setQuery('');
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    // A Material, not a ColoredBox: row ink splashes paint on it
    return Material(
      color: palette.background,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenHeader(
              title: 'Memories',
              actions: [if (widget.headerAction != null) widget.headerAction!],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _SearchField(
                controller: _searchController,
                hint: 'Search conversations, people, tasks',
                searching: _controller.state.searching,
                onChanged: _controller.setQuery,
                onClear: _clearSearch,
              ),
            ),
            Expanded(
              child: _controller.state.isSearching ? _buildSearch() : _buildList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final state = _controller.state;
    if (state.loading) {
      return const Center(child: CircularProgressIndicator(key: Key('memories-loading')));
    }
    if (state.conversations.isEmpty) {
      if (state.error != null) {
        return FullScreenMessage(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load your memories',
          message: state.error!,
          actionKey: const Key('memories-retry'),
          actionLabel: 'Retry',
          onAction: _controller.refresh,
          onRefresh: _controller.refresh,
        );
      }
      return FullScreenMessage(
        icon: Icons.forum_outlined,
        title: 'No memories yet',
        message: 'Conversations show up here a few minutes after Echo hears them.',
        onRefresh: _controller.refresh,
      );
    }

    final now = widget.clock();
    final days = _byDay(state.conversations);
    final footer = state.loadingMore || state.hasMore || state.error != null;
    final people = _topPeople(state.people);
    final summaries = [
      if (_week case final week?) WeeklySummarySection(week: week, now: now),
      if (_digest case final digest?)
        DigestSection(
          loading: false,
          summary: digest,
          error: null,
          onRetry: () {},
          now: now,
        ),
      if (people.isNotEmpty)
        _PeoplePanel(
          people: people,
          total: state.people.length,
          onOpen: (id) => unawaited(_openPerson(id)),
          onAll: () => unawaited(_openPeople()),
        ),
    ];
    final first = summaries.isEmpty ? 0 : 1;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < 600) unawaited(_controller.loadMore());
          return false;
        },
        child: ListView.builder(
          key: const Key('memories-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(bottom: 16 + EchoShellInsets.bottomOf(context)),
          itemCount: first + days.length + (footer ? 1 : 0),
          itemBuilder: (context, index) {
            if (index < first) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Column(
                  children: [
                    for (final summary in summaries)
                      Padding(padding: const EdgeInsets.only(bottom: 12), child: summary),
                  ],
                ),
              );
            }
            index -= first;
            if (index == days.length) return _footer(state);
            final day = days[index];
            return _DayPanel(
              label: dayLabel(day.first.startedAt, now),
              conversations: day,
              onOpen: (id) => unawaited(_open(id)),
            );
          },
        ),
      ),
    );
  }

  Widget _footer(MemoriesState state) {
    if (state.error != null && !state.loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: SectionError(
          message: state.error!,
          retryKey: const Key('memories-more-retry'),
          onRetry: () => unawaited(_controller.loadMore()),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _buildSearch() {
    final state = _controller.state;
    final results = state.results;
    if (state.searchError != null) {
      return FullScreenMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Search failed',
        message: state.searchError!,
        actionKey: const Key('search-retry'),
        actionLabel: 'Retry',
        onAction: () async => _controller.setQuery(state.query),
      );
    }
    if (results == null) {
      return const Center(child: CircularProgressIndicator(key: Key('search-loading')));
    }
    if (results.isEmpty) {
      return FullScreenMessage(
        icon: Icons.search_off_rounded,
        title: 'No results',
        message: 'Nothing in your memory matches "${state.query}".',
      );
    }
    return ListView(
      key: const Key('search-results'),
      padding: EdgeInsets.only(bottom: 16 + EchoShellInsets.bottomOf(context)),
      children: [
        if (results.conversations.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: SectionHeader(title: 'Conversations'),
          ),
          for (final conversation in results.conversations)
            ConversationCardTile(
              conversation: conversation,
              dayFrom: widget.clock(),
              onTap: () => unawaited(_open(conversation.id)),
            ),
        ],
        if (results.entities.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: SectionHeader(title: 'Mentions'),
          ),
          for (final entity in results.entities)
            MemoryEntityRow(
              entity: entity,
              onTap: entity.conversationId == null
                  ? null
                  : () => unawaited(_open(entity.conversationId!)),
            ),
        ],
      ],
    );
  }
}

/// The conversations split by day (local time), keeping their order.
List<List<ConversationCard>> _byDay(List<ConversationCard> conversations) {
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

/// The four people seen most recently (then the most talked about).
List<PersonSummary> _topPeople(List<PersonSummary> people) {
  final sorted = [...people]..sort((a, b) {
      final seen = (b.lastSeen ?? DateTime(0)).compareTo(a.lastSeen ?? DateTime(0));
      return seen != 0 ? seen : b.conversationCount.compareTo(a.conversationCount);
    });
  return sorted.take(4).toList();
}

/// A day: its name, then its conversations in one panel.
final class _DayPanel extends StatelessWidget {
  const _DayPanel({required this.label, required this.conversations, required this.onOpen});

  final String label;
  final List<ConversationCard> conversations;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
            child: Semantics(
              header: true,
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontSize: 14,
                      color: palette.text2,
                    ),
              ),
            ),
          ),
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, conversation) in conversations.indexed) ...[
                  if (index > 0) Divider(height: 1, color: palette.border),
                  ConversationRow(
                    conversation: conversation,
                    onTap: () => onOpen(conversation.id),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "People": the four seen most recently, and the way to everyone.
final class _PeoplePanel extends StatelessWidget {
  const _PeoplePanel({
    required this.people,
    required this.total,
    required this.onOpen,
    required this.onAll,
  });

  final List<PersonSummary> people;
  final int total;
  final ValueChanged<String> onOpen;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Panel(
      key: const Key('people-panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            title: 'People',
            actionLabel: 'All $total',
            onAction: onAll,
            actionKey: const Key('people-all'),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final person in people)
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
              for (var i = people.length; i < 4; i++) const Expanded(child: SizedBox()),
            ],
          ),
        ],
      ),
    );
  }
}

final class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    required this.searching,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String hint;
  final bool searching;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return TextField(
          key: const Key('memories-search'),
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
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
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
          ),
        );
      },
    );
  }
}
