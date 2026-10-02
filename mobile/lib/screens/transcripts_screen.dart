import 'dart:async';

import 'package:flutter/material.dart';

import '../models/segment.dart';
import '../services/api_service.dart';
import '../services/transcript_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/transcript_group_section.dart';
import 'transcript_detail_screen.dart';

typedef TranscriptDetailBuilder = Widget Function(
  BuildContext context,
  RecentSegment segment,
);

class TranscriptsScreen extends StatefulWidget {
  const TranscriptsScreen({
    super.key,
    this.controller,
    this.api,
    this.segmentUploadedStream,
    this.detailBuilder,
  });

  final TranscriptController? controller;
  final TranscriptApi? api;
  final Stream<Object?>? segmentUploadedStream;
  final TranscriptDetailBuilder? detailBuilder;

  @override
  State<TranscriptsScreen> createState() => _TranscriptsScreenState();
}

class _TranscriptsScreenState extends State<TranscriptsScreen> {
  late final TranscriptController _controller;
  late final bool _ownsController;
  TranscriptMemoryApi? _detailApi;
  ApiService? _ownedApi;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    final injectedController = widget.controller;
    if (injectedController != null) {
      _controller = injectedController;
      _ownsController = false;
    } else {
      final injectedApi = widget.api;
      final TranscriptApi browseApi;
      if (injectedApi != null) {
        browseApi = injectedApi;
      } else {
        final api = ApiService();
        _ownedApi = api;
        browseApi = api;
      }
      _controller = TranscriptController(
        api: browseApi,
        uploadStream: widget.segmentUploadedStream,
      );
      _ownsController = true;
    }
    final api = widget.api ?? _ownedApi;
    if (api is TranscriptMemoryApi) _detailApi = api;
    _controller.addListener(_handleStateChanged);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.removeListener(_handleStateChanged);
    if (_ownsController) _controller.dispose();
    _ownedApi?.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _handleStateChanged() {
    if (mounted) setState(() {});
  }

  void _toggleSearch() {
    setState(() => _showSearch = !_showSearch);
    if (_showSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
      return;
    }
    _searchController.clear();
    _controller.setQuery('');
    _searchFocus.unfocus();
  }

  Future<void> _openSegment(RecentSegment segment) async {
    final builder = widget.detailBuilder;
    final detailApi = _detailApi;
    if (builder == null && detailApi == null) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => builder != null
            ? builder(context, segment)
            : TranscriptDetailScreen(segment: segment, api: detailApi),
      ),
    );
    if (!mounted) return;
    await _controller.refreshAfterDetail();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final state = _controller.state;
    return ColoredBox(
      color: palette.background,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Transcripts',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  SizedBox.square(
                    dimension: 44,
                    child: IconButton(
                      key: const Key('transcripts-search-toggle'),
                      tooltip: _showSearch
                          ? 'Close search'
                          : 'Search transcripts',
                      onPressed: _toggleSearch,
                      icon: Icon(
                        _showSearch
                            ? Icons.close_rounded
                            : Icons.search_rounded,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_showSearch)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: SizedBox(
                  height: 44,
                  child: TextField(
                    key: const Key('transcripts-search-field'),
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: _controller.setQuery,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search recent transcripts',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      prefixIconConstraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      suffixIconConstraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      suffixIcon: state.searching
                          ? Padding(
                              key: const Key('transcripts-searching'),
                              padding: const EdgeInsets.all(12),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: palette.blue,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            Divider(height: 1, color: palette.border),
            Expanded(child: _buildBody(state)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(TranscriptState state) {
    if (state.loading) {
      return const Center(
        child: CircularProgressIndicator(key: Key('transcripts-loading')),
      );
    }
    if (state.error != null && state.allSegments.isEmpty) {
      return _RefreshableMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load transcripts',
        message: state.error!,
        actionKey: const Key('transcripts-retry'),
        actionLabel: 'Retry',
        onAction: _controller.load,
        onRefresh: _controller.refresh,
      );
    }
    if (state.allSegments.isEmpty) {
      return _RefreshableMessage(
        icon: Icons.notes_rounded,
        title: 'No transcripts yet',
        message: 'Your recent transcripts will appear here.',
        onRefresh: _controller.refresh,
      );
    }
    if (state.query.isNotEmpty && state.groups.isEmpty && !state.searching) {
      return _RefreshableMessage(
        icon: Icons.search_off_rounded,
        title: 'No matching transcripts',
        message: 'Try a different search.',
        onRefresh: _controller.refresh,
      );
    }

    return RefreshIndicator(
      onRefresh: _controller.refresh,
      child: ListView.builder(
        key: const Key('transcripts-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: state.groups.length,
        itemBuilder: (context, index) => TranscriptGroupSection(
          group: state.groups[index],
          onOpen: (segment) => unawaited(_openSegment(segment)),
        ),
      ),
    );
  }
}

final class _RefreshableMessage extends StatelessWidget {
  const _RefreshableMessage({
    required this.icon,
    required this.title,
    required this.message,
    required this.onRefresh,
    this.actionKey,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final Future<void> Function() onRefresh;
  final Key? actionKey;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 32, color: palette.text2),
                    const SizedBox(height: 12),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: palette.text2),
                    ),
                    if (onAction != null) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        key: actionKey,
                        onPressed: () => unawaited(onAction!()),
                        child: Text(actionLabel!),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
