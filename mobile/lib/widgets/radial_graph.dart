import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/memory_graph.dart';

/// Places people deterministically on one weighted ring and topics around them.
Map<String, Offset> radialLayout(MemoryGraph graph, Size size) {
  final center = Offset(size.width / 2, size.height / 2);
  final radius = math.min(size.width, size.height).toDouble() / 2;
  final positions = <String, Offset>{};
  final people = graph.nodes.where((node) => node.kind == 'person').toList()
    ..sort((a, b) {
      final byWeight = b.weight.compareTo(a.weight);
      if (byWeight != 0) return byWeight;
      final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
    });

  for (final node in graph.nodes) {
    if (node.kind == 'you' || node.id == 'you') positions[node.id] = center;
  }

  final maximumPersonWeight = people.fold<int>(
    0,
    (maximum, person) => maximum > person.weight ? maximum : person.weight,
  );
  final personAngles = <String, double>{};
  for (var index = 0; index < people.length; index++) {
    final person = people[index];
    final angle = -math.pi / 2 + 2 * math.pi * index / people.length;
    final share = maximumPersonWeight == 0
        ? 0.0
        : math.max(0, person.weight).toDouble() / maximumPersonWeight;
    final distance = radius * (0.35 + 0.3 * (1 - share));
    personAngles[person.id] = angle;
    positions[person.id] = Offset(
      center.dx + math.cos(angle) * distance,
      center.dy + math.sin(angle) * distance,
    );
  }

  final topics = graph.nodes.where((node) => node.kind == 'topic').toList()
    ..sort((a, b) {
      final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
    });
  final topicAngles = <({GraphNode node, double angle})>[];
  for (var index = 0; index < topics.length; index++) {
    final topic = topics[index];
    final associatedAngles = <double>[];
    for (final edge in graph.edges) {
      final personId = edge.a == topic.id ? edge.b : edge.b == topic.id ? edge.a : null;
      if (personId != null) {
        final angle = personAngles[personId];
        if (angle != null) associatedAngles.add(angle);
      }
    }
    associatedAngles.sort();

    final angle = associatedAngles.isEmpty
        ? -math.pi / 2 + 2 * math.pi * index / topics.length
        : _circularMean(associatedAngles);
    topicAngles.add((node: topic, angle: _normalize(angle)));
  }

  for (final topic in _spreadTopicAngles(topicAngles)) {
    positions[topic.node.id] = Offset(
      center.dx + math.cos(topic.angle) * radius * 0.9,
      center.dy + math.sin(topic.angle) * radius * 0.9,
    );
  }
  return positions;
}

double _circularMean(List<double> angles) {
  final x = angles.fold<double>(0, (sum, angle) => sum + math.cos(angle));
  final y = angles.fold<double>(0, (sum, angle) => sum + math.sin(angle));
  if (x.abs() < 1e-10 && y.abs() < 1e-10) return angles.first;
  return math.atan2(y, x);
}

double _normalize(double angle) =>
    ((angle % (2 * math.pi) + 2 * math.pi) % (2 * math.pi)).toDouble();

List<({GraphNode node, double angle})> _spreadTopicAngles(
  List<({GraphNode node, double angle})> topics,
) {
  if (topics.length < 2) return topics;
  const minimumSeparation = 8 * math.pi / 180;
  final sorted = [...topics]
    ..sort((a, b) {
      final byAngle = a.angle.compareTo(b.angle);
      if (byAngle != 0) return byAngle;
      final byLabel = a.node.label.compareTo(b.node.label);
      return byLabel != 0 ? byLabel : a.node.id.compareTo(b.node.id);
    });

  var largestGapIndex = sorted.length - 1;
  var largestGap = sorted.first.angle + 2 * math.pi - sorted.last.angle;
  for (var index = 0; index < sorted.length - 1; index++) {
    final gap = sorted[index + 1].angle - sorted[index].angle;
    if (gap > largestGap) {
      largestGap = gap;
      largestGapIndex = index;
    }
  }

  final circularOrder = <({GraphNode node, double angle})>[];
  final first = sorted[(largestGapIndex + 1) % sorted.length];
  final startAngle = first.angle;
  for (var index = 1; index <= sorted.length; index++) {
    final topic = sorted[(largestGapIndex + index) % sorted.length];
    var angle = topic.angle;
    while (angle < startAngle) {
      angle += 2 * math.pi;
    }
    if (circularOrder.isNotEmpty) {
      if (angle - circularOrder.last.angle < minimumSeparation) {
        angle = circularOrder.last.angle + minimumSeparation;
      }
    }
    circularOrder.add((node: topic.node, angle: angle));
  }

  return [
    for (final topic in circularOrder)
      (node: topic.node, angle: _normalize(topic.angle)),
  ];
}

double graphNodeSize(int weight) =>
    (math.sqrt(math.max(0, weight)) * 8).clamp(14.0, 36.0).toDouble();

final class RadialGraphPainter extends CustomPainter {
  const RadialGraphPainter({
    required this.graph,
    required this.positions,
    required this.color,
  });

  final MemoryGraph graph;
  final Map<String, Offset> positions;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final maximumWeight = graph.edges.fold<int>(
      0,
      (maximum, edge) => maximum > edge.weight ? maximum : edge.weight,
    );
    for (final edge in graph.edges) {
      final from = positions[edge.a];
      final to = positions[edge.b];
      if (from == null || to == null) continue;
      final share = maximumWeight == 0
          ? 0.0
          : math.max(0, edge.weight).toDouble() / maximumWeight;
      canvas.drawLine(
        from,
        to,
        Paint()
          ..color = color.withValues(alpha: 0.42)
          ..strokeWidth = 1 + 3 * share
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant RadialGraphPainter oldDelegate) =>
      !identical(graph, oldDelegate.graph) ||
      !identical(positions, oldDelegate.positions) ||
      color != oldDelegate.color;
}
