import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/memory.dart';
import '../models/today_insights.dart';
import '../services/api/api_service.dart';
import '../services/library_counts.dart';
import '../services/memory/memories_controller.dart';
import '../services/phone/places_visited.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import '../widgets/echo_large_title.dart';
import '../widgets/memory_sections.dart';
import '../widgets/summary_sections.dart' show weekLabel;
import 'conversation_detail_screen.dart';
import 'day_screen.dart';
import 'memory_graph_screen.dart';
import 'memory_search_screen.dart';
import 'navigation.dart';
import 'people_screen.dart';
import 'person_screen.dart';
import 'saved_screen.dart';
import 'settings/documents_screen.dart';
import 'settings/places_visited_screen.dart';
import 'tasks_screen.dart';

/// The Library tab: search, this week's days, and a tile for everything Echo keeps.
final class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    required this.loadCounts,
    required this.memories,
    required this.api,
    this.places,
    this.placesOn,
    this.accountAction,
    this.active = true,
    this.onAsk,
    this.openConversation,
    this.segmentUploadedStream,
    this.clock = DateTime.now,
    super.key,
  });

  final Future<LibraryCounts> Function() loadCounts;
  final MemoriesController memories;
  final MemoryApi api;

  /// The places service, for the Places page; without it the tile stays shut.
  final PlacesVisitedService? places;

  /// Whether Places visited is on; "Off" on its tile when not.
  final ValueListenable<bool>? placesOn;

  /// The user's circle, top right.
  final Widget? accountAction;

  /// False while another tab shows; the counts reload when this turns true.
  final bool active;
  final AskCallback? onAsk;
  final ConversationOpener? openConversation;
  final Stream<Object?>? segmentUploadedStream;
  final DateTime Function() clock;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

final class _LibraryScreenState extends State<LibraryScreen> {
  LibraryCounts _counts = const LibraryCounts();
  WeeklySummary? _week;

  @override
  void initState() {
    super.initState();
    widget.memories.addListener(_changed);
    if (widget.active) unawaited(_reload());
  }

  @override
  void didUpdateWidget(LibraryScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) unawaited(_reload());
  }

  @override
  void dispose() {
    widget.memories.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // A page opened over this one may load people while the frame is still building
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
    } else {
      setState(() {});
    }
  }

  Future<void> _reload() async {
    final api = widget.api;
    final (counts, week) = await (
      widget.loadCounts(),
      api is WeeklySummaryApi
          ? (api as WeeklySummaryApi)
              .getLatestWeeklySummary()
              .then<WeeklySummary?>((w) => w, onError: (_) => null)
          : Future<WeeklySummary?>.value(),
    ).wait;
    if (mounted) {
      setState(() {
        _counts = counts;
        _week = week;
      });
    }
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => page));
    if (mounted) unawaited(_reload());
  }

  Future<void> _openById(String id) async {
    final opener = widget.openConversation;
    if (opener != null) {
      await opener(context, id);
    } else {
      await _push(ConversationDetailScreen(
        conversationId: id,
        api: widget.api,
        onAsk: widget.onAsk,
        clock: widget.clock,
      ));
    }
    if (mounted) await widget.memories.refresh();
  }

  Future<void> _openPerson(String id) async {
    await _push(PersonScreen(
        personId: id,
        api: widget.api,
        onAsk: widget.onAsk,
        clock: widget.clock));
    if (mounted) await widget.memories.loadPeople();
  }

  Future<void> _openMap() => _push(MemoryGraphScreen(
        api: widget.api,
        onOpenPerson: _openPerson,
        onOpenConversation: _openById,
      ));

  Future<void> _openDay(List<ConversationCard> conversations) =>
      _push(DayScreen(
        day: dayOf(conversations.first.startedAt),
        conversations: conversations,
        api: widget.api,
        onAsk: widget.onAsk,
        openConversation: widget.openConversation,
        clock: widget.clock,
      ));

  Future<void> _openSearch() async {
    await _push(MemorySearchScreen(
      memories: widget.memories,
      clock: widget.clock,
      onOpen: (id) => unawaited(_openById(id)),
    ));
    widget.memories.setQuery('');
  }

  /// The days from before this week, with the week's summary and more days to load.
  Future<void> _openEarlier() => _push(_EarlierDays(
        memories: widget.memories,
        clock: widget.clock,
        onOpenDay: _openDay,
      ));

  List<ConversationCard> _cardsOf(DateTime day) => [
        for (final c in widget.memories.state.conversations)
          if (dayOf(c.startedAt) == day) c,
      ];

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final now = widget.clock();
    final state = widget.memories.state;
    final days = thisWeek(state.conversations, now);
    final api = widget.api;
    final hasEarlier =
        state.hasMore || _olderDays(state.conversations, now).isNotEmpty;
    final c = _counts;

    String count(int? n, String Function(int n) say) =>
        n == null ? '—' : say(n);

    final tiles = <Widget>[
      _Tile(
        icon: CupertinoIcons.person_2,
        title: 'People',
        subtitle: count(c.people, (n) => '$n saved'),
        faces: c.faces,
        onTap: () => _push(PeopleScreen(
          controller: widget.memories,
          onOpenPerson: _openPerson,
          onOpenMap: _openMap,
          now: now,
        )),
      ),
      _Tile(
        icon: CupertinoIcons.bookmark,
        title: 'Saved',
        subtitle: count(c.saved, (n) => '$n items'),
        onTap: api is SavedApi
            ? () => _push(SavedScreen(
                  api: api as SavedApi,
                  loadPhoto:
                      api is PhotoApi ? (api as PhotoApi).photoImage : null,
                  onAsk: widget.onAsk,
                  openConversation: (context, id) => _openById(id),
                  openPerson: (context, id) => _openPerson(id),
                  clock: widget.clock,
                ))
            : null,
      ),
      _Tile(
        icon: CupertinoIcons.checkmark_circle,
        title: 'To do',
        subtitle: count(c.openTasks, (n) => '$n open'),
        onTap: () => _push(TasksPage(
          segmentUploadedStream: widget.segmentUploadedStream,
          onAsk: widget.onAsk,
        )),
      ),
      ListenableBuilder(
        listenable: widget.placesOn ?? const AlwaysStoppedAnimation(true),
        builder: (context, _) => _Tile(
          icon: CupertinoIcons.location,
          title: 'Places',
          // Without the setting, on only when a count could be read
          subtitle: (widget.placesOn?.value ?? c.visitsThisWeek != null)
              ? count(c.visitsThisWeek, (n) => '$n this week')
              : 'Off',
          onTap: widget.places == null || api is! PlacesApi
              ? null
              : () => _push(PlacesVisitedScreen(
                  places: widget.places!, api: api as PlacesApi)),
        ),
      ),
      _Tile(
        icon: CupertinoIcons.graph_circle,
        title: 'Map',
        subtitle: 'People and topics',
        onTap: _openMap,
      ),
      _Tile(
        icon: CupertinoIcons.doc_text,
        title: 'Documents',
        subtitle: count(c.documents, (n) => '$n'),
        onTap: api is DocumentsApi
            ? () => _push(DocumentsScreen(api: api as DocumentsApi))
            : null,
      ),
    ];

    return Material(
      color: palette.background,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text('Library', style: TextStyle(color: palette.text)),
            automaticallyImplyLeading: false,
            backgroundColor: palette.background,
            border: Border(bottom: BorderSide(color: palette.border, width: 0)),
            trailing: widget.accountAction,
          ),
          CupertinoSliverRefreshControl(onRefresh: _reload),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverList.list(children: [
              _SearchField(onTap: _openSearch),
              const SizedBox(height: 20),
              if (days.isNotEmpty || _week != null || hasEarlier) ...[
                const _SectionTitle('THIS WEEK'),
                Material(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    if (_week case final week?)
                      _Row(
                        key: const Key('library-week'),
                        title: weekLabel(week.weekStart, now),
                        subtitle: week.summary,
                        onTap: () => _push(WeekScreen(week: week, now: now)),
                      ),
                    for (final day in days)
                      _Row(
                        key: Key(
                            'library-day-${day.day.toIso8601String().substring(0, 10)}'),
                        date: day.day.day,
                        title: dayLabel(day.day, now),
                        subtitle: [
                          day.conversations == 1
                              ? '1 conversation'
                              : '${day.conversations} conversations',
                          if (day.people.isNotEmpty) day.people.join(', '),
                        ].join(' · '),
                        onTap: () => _openDay(_cardsOf(day.day)),
                      ),
                    if (hasEarlier)
                      _Row(
                          key: const Key('library-earlier'),
                          title: 'Earlier',
                          onTap: _openEarlier),
                  ]),
                ),
                const SizedBox(height: 20),
              ],
              for (var i = 0; i < tiles.length; i += 2) ...[
                if (i > 0) const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: tiles[i]),
                        const SizedBox(width: 12),
                        Expanded(child: tiles[i + 1]),
                      ]),
                ),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}

/// Conversations from before the last 7 days.
List<ConversationCard> _olderDays(List<ConversationCard> all, DateTime now) {
  final t = dayOf(now);
  final first =
      DateTime(t.year, t.month, t.day - 6); // calendar days, as thisWeek
  return [
    for (final c in all)
      if (!c.isOpen && dayOf(c.startedAt).isBefore(first)) c,
  ];
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: EchoPalette.of(context).text2, letterSpacing: 0.6),
        ),
      );
}

final class _SearchField extends StatelessWidget {
  const _SearchField({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Semantics(
      label: 'Search what you heard',
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: AbsorbPointer(
            child: CupertinoSearchTextField(
              placeholder: 'Search what you heard',
              backgroundColor: palette.surface2,
              itemColor: palette.text2,
              placeholderStyle: TextStyle(color: palette.text2),
              style: TextStyle(color: palette.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of the THIS WEEK group.
final class _Row extends StatelessWidget {
  const _Row(
      {required this.title,
      required this.onTap,
      this.subtitle,
      this.date,
      super.key});

  /// The day number, in a tile (day rows).
  final int? date;

  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: [title, if (subtitle != null) subtitle!].join(', '),
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              if (date != null) ...[
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: palette.surface2,
                      borderRadius: BorderRadius.circular(10)),
                  child: Text('$date',
                      style: textTheme.titleMedium?.copyWith(
                          color: palette.text,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: textTheme.bodyLarge
                              ?.copyWith(color: palette.text)),
                      if (subtitle != null)
                        Text(subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall
                                ?.copyWith(color: palette.text2)),
                    ]),
              ),
              Icon(CupertinoIcons.chevron_right,
                  size: 14, color: palette.text2),
            ]),
          ),
        ),
      ),
    );
  }
}

final class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.faces = const [],
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> faces;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: '$title, $subtitle',
      button: onTap != null,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 22, color: palette.accent),
                    const SizedBox(height: 10),
                    Text(title,
                        style: textTheme.titleMedium?.copyWith(
                            color: palette.text, fontWeight: FontWeight.w600)),
                    Text(subtitle,
                        style: textTheme.bodySmall
                            ?.copyWith(color: palette.text2)),
                    if (faces.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 4, runSpacing: 4, children: [
                        for (final face in faces)
                          Container(
                            width: 24,
                            height: 24,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                                color: palette.accentSoft,
                                shape: BoxShape.circle),
                            child: Text(face,
                                style: textTheme.labelSmall?.copyWith(
                                    color: palette.onAccentSoft,
                                    fontWeight: FontWeight.w600)),
                          ),
                      ]),
                    ],
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Earlier": the days before this week, newest first; more load at the end.
final class _EarlierDays extends StatelessWidget {
  const _EarlierDays(
      {required this.memories, required this.clock, required this.onOpenDay});

  final MemoriesController memories;
  final DateTime Function() clock;
  final Future<void> Function(List<ConversationCard> day) onOpenDay;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: memories,
      builder: (context, _) {
        final now = clock();
        final state = memories.state;
        return EchoLargeTitlePage(
          title: 'Earlier',
          slivers: [
            SliverToBoxAdapter(
              child: EarlierPanel(
                days: conversationsByDay(_olderDays(state.conversations, now)),
                now: now,
                onOpenDay: (day) => unawaited(onOpenDay(day)),
                hasMore: state.hasMore,
                loadingMore: state.loadingMore,
                onMore: () => unawaited(memories.loadMore()),
              ),
            ),
          ],
        );
      },
    );
  }
}
