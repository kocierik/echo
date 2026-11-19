import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/memory_graph.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/radial_graph.dart';
import 'topic_conversations_screen.dart';

final class MemoryGraphScreen extends StatefulWidget {
  const MemoryGraphScreen({
    required this.api,
    required this.onOpenPerson,
    required this.onOpenConversation,
    super.key,
  });

  final MemoryApi api;
  final Future<void> Function(String id) onOpenPerson;
  final Future<void> Function(String id) onOpenConversation;

  @override
  State<MemoryGraphScreen> createState() => _MemoryGraphScreenState();
}

final class _MemoryGraphScreenState extends State<MemoryGraphScreen> {
  MemoryGraph? _graph;
  String? _error;
  bool _loading = true;
  bool _showAsList = false;
  int _days = 90;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadGraph(_days));
  }

  Future<void> _loadGraph(int days) async {
    final generation = ++_generation;
    setState(() {
      _days = days;
      _loading = true;
      _error = null;
    });
    try {
      final graph = await widget.api.getMemoryGraph(days: days);
      if (!mounted || generation != _generation) return;
      setState(() {
        _graph = graph;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = userMessage(error, 'Could not load your memory map.');
        _loading = false;
      });
    }
  }

  void _openNode(GraphNode node) {
    if (node.kind == 'person') {
      final personId =
          node.id.startsWith('person:') ? node.id.substring(7) : node.id;
      unawaited(widget.onOpenPerson(personId));
      return;
    }
    if (node.kind != 'topic') return;
    unawaited(Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TopicConversationsScreen(
          topic: node.label,
          api: widget.api,
          onOpenConversation: widget.onOpenConversation,
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final graph = _graph;
    final hasPeople = graph?.nodes.any((node) => node.kind == 'person') ?? false;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        title: const Text('Memory map'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _showAsList = !_showAsList),
            child: Text(_showAsList ? 'Show as map' : 'Show as list'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  _windowChip('1 month', 30),
                  _windowChip('3 months', 90),
                  _windowChip('All', 0),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _errorMessage()
                      : !hasPeople
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(
                                  'Add people in People to see your map',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : _showAsList
                              ? _list(graph!)
                              : _map(graph!, palette),
            ),
          ],
        ),
      ),
    );
  }

  Widget _windowChip(String label, int days) => ChoiceChip(
        key: Key('graph-window-$days'),
        label: Text(label),
        selected: _days == days,
        onSelected: (selected) {
          if (selected) unawaited(_loadGraph(days));
        },
      );

  Widget _errorMessage() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => unawaited(_loadGraph(_days)),
              child: const Text('Retry'),
            ),
          ],
        ),
      );

  Widget _list(MemoryGraph graph) {
    return ListView.builder(
      itemCount: graph.nodes.length,
      itemBuilder: (context, index) {
        final node = graph.nodes[index];
        return ListTile(
          key: Key('graph-list-node:${node.kind}:${node.id}'),
          title: Text('${node.label} · ${node.weight} conversations'),
          onTap: node.kind == 'you' ? null : () => _openNode(node),
        );
      },
    );
  }

  Widget _map(MemoryGraph graph, EchoPalette palette) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final positions = radialLayout(graph, size);
        return InteractiveViewer(
          minScale: 0.65,
          maxScale: 2.5,
          boundaryMargin: const EdgeInsets.all(48),
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: RadialGraphPainter(
                      graph: graph,
                      positions: positions,
                      color: palette.text2,
                    ),
                  ),
                ),
                for (final node in graph.nodes)
                  if (positions[node.id] case final position?)
                    _positionedNode(node, position, size, palette),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _positionedNode(
    GraphNode node,
    Offset position,
    Size size,
    EchoPalette palette,
  ) {
    final diameter = graphNodeSize(node.weight);
    final labelWidth = (2 * math.min(position.dx, size.width - position.dx))
        .clamp(0.0, 112.0)
        .toDouble();
    return Positioned(
      left: position.dx - 56,
      top: position.dy - diameter / 2,
      width: 112,
      height: diameter + 24,
      child: Semantics(
        button: true,
        label: '${node.label}, ${node.weight} conversations',
        onTap: () => _openNode(node),
        child: ExcludeSemantics(
          child: GestureDetector(
            key: Key('graph-node-${node.kind}:${node.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _openNode(node),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: diameter,
                  height: diameter,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: switch (node.kind) {
                      'you' => palette.accent,
                      'topic' => palette.text2,
                      _ => palette.accentSoft,
                    },
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    switch (node.kind) {
                      'you' => '•',
                      'topic' => '#',
                      _ => _initials(node.label),
                    },
                    maxLines: 1,
                    style: TextStyle(
                      color: switch (node.kind) {
                        'you' => palette.onAccent,
                        'topic' => palette.background,
                        _ => palette.onAccentSoft,
                      },
                      fontSize: node.kind == 'you' ? 22 : 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    node.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: palette.text,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _initials(String value) {
    final words = value.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
    return words.take(2).map((word) => word.characters.first.toUpperCase()).join();
  }
}
