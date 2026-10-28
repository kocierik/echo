import 'package:flutter/material.dart';

import '../services/memory/memories_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/memory_sections.dart';

/// Search over the whole memory, opened from the icon on Today: conversations, people,
/// tasks. Whoever opens it ends the search once it is closed.
final class MemorySearchScreen extends StatefulWidget {
  const MemorySearchScreen({
    required this.memories,
    required this.clock,
    required this.onOpen,
    super.key,
  });

  final MemoriesController memories;
  final DateTime Function() clock;

  /// Opens a conversation found.
  final void Function(String id) onOpen;

  @override
  State<MemorySearchScreen> createState() => _MemorySearchScreenState();
}

final class _MemorySearchScreenState extends State<MemorySearchScreen> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.memories.addListener(_changed);
  }

  @override
  void dispose() {
    widget.memories.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _clear() {
    _query.clear();
    widget.memories.setQuery('');
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final memory = widget.memories.state;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: MemorySearchField(
              controller: _query,
              searching: memory.searching,
              onChanged: widget.memories.setQuery,
              onClear: _clear,
              autofocus: true,
            ),
          ),
          Expanded(
            child: memory.isSearching
                ? MemorySearchView(
                    state: memory,
                    now: widget.clock(),
                    onOpen: widget.onOpen,
                    onRetry: () async => widget.memories.setQuery(memory.query),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
