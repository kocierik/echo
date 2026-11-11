import 'dart:math' as math;

import 'package:echo_app/models/memory_graph.dart';
import 'package:echo_app/widgets/radial_graph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(300, 300);
  const center = Offset(150, 150);

  test('You is at the centre', () {
    final positions = radialLayout(
      const MemoryGraph(nodes: [
        GraphNode(id: 'you', kind: 'you', label: 'You', weight: 6),
        GraphNode(id: 'p1', kind: 'person', label: 'Marco', weight: 5),
      ], edges: []),
      size,
    );

    expect(positions['you'], center);
  });

  test('people lie on a ring, with heavier people nearer the centre', () {
    final positions = radialLayout(
      const MemoryGraph(nodes: [
        GraphNode(id: 'you', kind: 'you', label: 'You', weight: 6),
        GraphNode(id: 'p1', kind: 'person', label: 'Marco', weight: 5),
        GraphNode(id: 'p2', kind: 'person', label: 'Ada', weight: 1),
      ], edges: []),
      size,
    );

    final heavyDistance = (positions['p1']! - center).distance;
    final lightDistance = (positions['p2']! - center).distance;
    expect(positions['p1']!.dy, lessThan(center.dy));
    expect(positions['p2']!.dy, greaterThan(center.dy));
    expect(heavyDistance, lessThan(lightDistance));
    expect(heavyDistance, closeTo(52.5, 0.001));
    expect(lightDistance, closeTo(88.5, 0.001));
  });

  test('topics lie on the outer ring beyond every person', () {
    final positions = radialLayout(
      const MemoryGraph(nodes: [
        GraphNode(id: 'you', kind: 'you', label: 'You', weight: 6),
        GraphNode(id: 'p1', kind: 'person', label: 'Marco', weight: 5),
        GraphNode(id: 'p2', kind: 'person', label: 'Ada', weight: 1),
        GraphNode(id: 't1', kind: 'topic', label: 'Atlas', weight: 3),
      ], edges: [
        GraphEdge(a: 'p1', b: 't1', weight: 2),
        GraphEdge(a: 'p2', b: 't1', weight: 1),
      ]),
      size,
    );

    final topicDistance = (positions['t1']! - center).distance;
    final farthestPerson = [
      (positions['p1']! - center).distance,
      (positions['p2']! - center).distance,
    ].reduce((a, b) => a > b ? a : b);
    expect(topicDistance, closeTo(135, 0.001));
    expect(topicDistance, greaterThan(farthestPerson));
  });

  test('the same graph gives the same offsets twice', () {
    const graph = MemoryGraph(nodes: [
      GraphNode(id: 'you', kind: 'you', label: 'You', weight: 6),
      GraphNode(id: 'p1', kind: 'person', label: 'Marco', weight: 5),
      GraphNode(id: 'p2', kind: 'person', label: 'Ada', weight: 1),
      GraphNode(id: 't1', kind: 'topic', label: 'Atlas', weight: 3),
    ], edges: [
      GraphEdge(a: 'p1', b: 't1', weight: 2),
      GraphEdge(a: 'p2', b: 't1', weight: 1),
    ]);

    expect(radialLayout(graph, size), radialLayout(graph, size));
  });

  test('one person is not at the centre', () {
    final positions = radialLayout(
      const MemoryGraph(nodes: [
        GraphNode(id: 'you', kind: 'you', label: 'You', weight: 2),
        GraphNode(id: 'p1', kind: 'person', label: 'Marco', weight: 2),
      ], edges: []),
      size,
    );

    expect(positions['p1'], isNot(center));
  });

  test('nearby topic angles are spread by at least eight degrees', () {
    final graph = MemoryGraph(
      nodes: [
        const GraphNode(id: 'p1', kind: 'person', label: 'Marco', weight: 5),
        for (var index = 0; index < 3; index++)
          GraphNode(
            id: 't$index',
            kind: 'topic',
            label: 'Topic $index',
            weight: 1,
          ),
      ],
      edges: [
        for (var index = 0; index < 3; index++)
          GraphEdge(a: 'p1', b: 't$index', weight: 1),
      ],
    );
    final positions = radialLayout(graph, size);
    final angles = [
      for (var index = 0; index < 3; index++)
        math.atan2(
          positions['t$index']!.dy - center.dy,
          positions['t$index']!.dx - center.dx,
        ),
    ]..sort();

    const minAngle = 8 * math.pi / 180;
    expect(angles[1] - angles[0], greaterThanOrEqualTo(minAngle - 1e-10));
    expect(angles[2] - angles[1], greaterThanOrEqualTo(minAngle - 1e-10));
  });

  test('node sizes use square-root weights and stay between 14 and 36', () {
    expect(graphNodeSize(1), 14);
    expect(graphNodeSize(4), 16);
    expect(graphNodeSize(100), 36);
  });

  test('equal-angle ordering is by label after descending weight', () {
    final positions = radialLayout(
      const MemoryGraph(nodes: [
        GraphNode(id: 'p2', kind: 'person', label: 'Zoe', weight: 2),
        GraphNode(id: 'p1', kind: 'person', label: 'Ada', weight: 2),
      ], edges: []),
      size,
    );

    expect(positions['p1']!.dy, lessThan(center.dy));
    expect(positions['p2']!.dy, greaterThan(center.dy));
  });
}
