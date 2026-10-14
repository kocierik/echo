import 'dart:async';

import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../services/api_service.dart';
import '../services/memories_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/conversation_card.dart';
import '../widgets/formatting.dart';
import '../widgets/memory_entity_row.dart';
import '../widgets/sections.dart';
import 'conversation_detail_screen.dart';

/// Opens a conversation; returns once the detail is closed.
typedef ConversationOpener = Future<void> Function(BuildContext context, String id);

/// The Memories tab: every conversation by day, and search across the memory.
final class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({
    this.api,
    this.controller,
    this.segmentUploadedStream,
    this.openConversation,
    this.clock = DateTime.now,
    super.key,
  });

  final MemoryApi? api;
  final MemoriesController? controller;
  final Stream<Object?>? segmentUploadedStream;
  final ConversationOpener? openConversation;
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
          builder: (_) => ConversationDetailScreen(conversationId: id, api: _api),
        ),
      );
    }
    if (mounted) await _controller.refresh();
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text('Memories', style: Theme.of(context).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: _SearchField(
                controller: _searchController,
                searching: _controller.state.searching,
                onChanged: _controller.setQuery,
                onClear: _clearSearch,
              ),
            ),
            Divider(height: 1, color: palette.border),
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

    final rows = _rowsByDay(state.conversations, widget.clock());
    final footer = state.loadingMore || state.hasMore || state.error != null;
    return RefreshIndicator(
      onRefresh: _controller.refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < 600) unawaited(_controller.loadMore());
          return false;
        },
        child: ListView.builder(
          key: const Key('memories-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: rows.length + (footer ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == rows.length) return _footer(state);
            final row = rows[index];
            return row.day != null
                ? _DayHeader(label: row.day!)
                : ConversationCardTile(
                    conversation: row.conversation!,
                    onTap: () => unawaited(_open(row.conversation!.id)),
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
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        if (results.conversations.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: SectionHeader(title: 'Conversations'),
          ),
          for (final conversation in results.conversations)
            ConversationCardTile(
              conversation: conversation,
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

final class _Row {
  const _Row.day(this.day) : conversation = null;
  const _Row.conversation(this.conversation) : day = null;

  final String? day;
  final ConversationCard? conversation;
}

/// Day headers interleaved with the conversations of that day (local time).
List<_Row> _rowsByDay(List<ConversationCard> conversations, DateTime now) {
  final rows = <_Row>[];
  DateTime? current;
  for (final conversation in conversations) {
    final day = dayOf(conversation.startedAt);
    if (day != current) {
      current = day;
      rows.add(_Row.day(dayLabel(day, now)));
    }
    rows.add(_Row.conversation(conversation));
  }
  return rows;
}

final class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Semantics(
        header: true,
        child: Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 12,
                letterSpacing: 0.6,
              ),
        ),
      ),
    );
  }
}

final class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.searching,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
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
            hintText: 'Search conversations, people, tasks',
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
