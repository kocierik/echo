import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/saved.dart';
import '../services/api/api_exception.dart';
import '../services/api/saved_api.dart';
import '../services/app/app_runtime.dart';
import '../services/device/phone_words.dart';
import '../services/phone/phone_location.dart';
import '../theme/app_theme.dart';
import '../utils/directions.dart';
import '../widgets/panel.dart';
import '../widgets/photo_thumbnail.dart';
import '../widgets/saved_sections.dart';
import '../widgets/sections.dart';
import 'navigation.dart';
import 'saved_item_screen.dart';

/// Opens a link outside the app (the phone's maps); tests record it instead.
typedef LinkOpener = Future<void> Function(Uri uri);

Future<void> openOutside(Uri uri) async {
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Saved (Today → Saved): what the user asked Echo to keep, each with its moment. The
/// "only the latest" things with a place first (the car), then each list, a list with
/// amounts as its week's total; a search over all of them.
final class SavedScreen extends StatefulWidget {
  const SavedScreen({
    required this.api,
    this.loadPhoto,
    this.onAsk,
    this.openConversation,
    this.openPerson,
    this.location,
    this.openLink = openOutside,
    this.clock = DateTime.now,
    super.key,
  });

  final SavedApi api;
  final PhotoSourceLoader? loadPhoto;
  final AskCallback? onAsk;
  final ConversationOpener? openConversation;
  final ConversationOpener? openPerson;

  /// For "650 m away" on a place card; the app's unless injected.
  final PhoneLocationService? location;
  final LinkOpener openLink;
  final DateTime Function() clock;

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

final class _SavedScreenState extends State<SavedScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  SavedOverview? _overview;
  String? _error;
  bool _loading = true;
  List<SavedItem>? _results;
  final Set<String> _busy = {};
  final Map<String, String> _distances = {};

  PhoneLocationService? get _location =>
      widget.location ?? AppRuntime.maybeCoordinator?.phoneLocation;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final overview = await widget.api.getSaved();
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _error = null;
        _loading = false;
      });
      unawaited(_measure(overview.places));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userMessage(error, 'Could not load Saved.');
        _loading = false;
      });
    }
  }

  /// How far each place is, only when the phone may already read its position.
  Future<void> _measure(List<SavedItem> places) async {
    final location = _location;
    if (location == null) return;
    for (final item in places) {
      final metres = await location.distanceTo(item.place!);
      if (metres != null && mounted) {
        setState(() => _distances[item.id] = distanceLabel(metres));
      }
    }
  }

  void _onSearch(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final found = await widget.api.searchSaved(text.trim());
        if (mounted && _search.text.trim() == text.trim()) setState(() => _results = found);
      } catch (error) {
        if (mounted) _snack(userMessage(error, 'Could not search Saved.'));
      }
    });
  }

  Future<void> _found(SavedItem item) async {
    setState(() => _busy.add(item.id));
    try {
      await widget.api.deleteSavedItem(item.id);
      await _load();
    } catch (error) {
      if (mounted) _snack(userMessage(error, 'Could not remove it.'));
    } finally {
      if (mounted) setState(() => _busy.remove(item.id));
    }
  }

  Future<void> _openItem(SavedItem item) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => SavedItemScreen(
        itemId: item.id,
        api: widget.api,
        loadPhoto: widget.loadPhoto,
        onAsk: widget.onAsk,
        openConversation: widget.openConversation,
        openPerson: widget.openPerson,
        clock: widget.clock,
      ),
    ));
    if (mounted) await _load();
  }

  Future<void> _openList(String listId) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => SavedListScreen(
        listId: listId,
        api: widget.api,
        onOpenItem: _openItem,
        clock: widget.clock,
      ),
    ));
    if (mounted) await _load();
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Saved')),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Things to find again, each with its moment.',
                style: textTheme.bodyMedium?.copyWith(color: palette.text2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const Key('saved-search'),
                controller: _search,
                onChanged: _onSearch,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search saved things',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final now = widget.clock();
    if (_results case final results?) {
      if (results.isEmpty) {
        return FullScreenMessage(
          icon: Icons.search_off_rounded,
          title: 'Nothing matches',
          message: 'Nothing saved says "${_search.text.trim()}".',
        );
      }
      return ListView(
        key: const Key('saved-results'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                for (final item in results)
                  SavedItemRow(item: item, now: now, onTap: () => unawaited(_openItem(item))),
              ],
            ),
          ),
        ],
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(key: Key('saved-loading')));
    }
    final overview = _overview;
    if (overview == null) {
      return FullScreenMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load Saved',
        message: _error ?? 'Try again.',
        actionKey: const Key('saved-retry'),
        actionLabel: 'Retry',
        onAction: _load,
        onRefresh: _load,
      );
    }
    if (overview.total == 0) {
      return FullScreenMessage(
        icon: Icons.bookmark_outline_rounded,
        title: 'Nothing saved yet',
        message: _hint,
        onRefresh: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('saved'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          for (final item in overview.places) ...[
            SavedPlaceCard(
              item: item,
              now: now,
              distance: _distances[item.id],
              busy: _busy.contains(item.id),
              onOpen: () => unawaited(_openItem(item)),
              onFound: () => unawaited(_found(item)),
              onDirections: () => unawaited(
                widget.openLink(directionsUri(item.place!, iOS: PhoneWords.isIPhone)),
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (final list in overview.lists) ...[
            if (list.weekSum != null)
              SavedSumCard(list: list, onOpen: () => unawaited(_openList(list.id)))
            else
              SavedListPanel(
                list: list,
                now: now,
                loadPhoto: widget.loadPhoto,
                onOpenItem: (item) => unawaited(_openItem(item)),
                onAll: () => unawaited(_openList(list.id)),
              ),
            const SizedBox(height: 12),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(_hint, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  static const _hint =
      'Say "Echo, save this", or ask in Ask. Echo picks the list, or starts a new one.';
}

/// A list and every thing in it ("All N").
final class SavedListScreen extends StatefulWidget {
  const SavedListScreen({
    required this.listId,
    required this.api,
    required this.onOpenItem,
    this.clock = DateTime.now,
    super.key,
  });

  final String listId;
  final SavedApi api;
  final Future<void> Function(SavedItem item) onOpenItem;
  final DateTime Function() clock;

  @override
  State<SavedListScreen> createState() => _SavedListScreenState();
}

final class _SavedListScreenState extends State<SavedListScreen> {
  SavedListDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final detail = await widget.api.getSavedList(widget.listId);
      if (mounted) setState(() => _detail = detail);
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'Could not load this list.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final detail = _detail;
    final now = widget.clock();
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: Text(detail?.list.name ?? 'Saved')),
      body: detail == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : FullScreenMessage(
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not load this list',
                  message: _error!,
                  actionLabel: 'Retry',
                  onAction: _load,
                ))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                key: const Key('saved-list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 4, bottom: 24),
                itemCount: detail.items.length,
                itemBuilder: (context, index) => PanelListRow(
                  index: index,
                  count: detail.items.length,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SavedItemRow(
                      item: detail.items[index],
                      now: now,
                      onTap: () async {
                        await widget.onOpenItem(detail.items[index]);
                        if (mounted) await _load();
                      },
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
