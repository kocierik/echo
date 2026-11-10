import 'package:flutter/foundation.dart';

@immutable
final class GraphNode {
  const GraphNode({
    required this.id,
    required this.kind,
    required this.label,
    required this.weight,
  });

  factory GraphNode.fromJson(Map<String, dynamic> json) => GraphNode(
        id: json['id'] as String,
        kind: json['kind'] as String,
        label: json['label'] as String,
        weight: (json['weight'] as num).toInt(),
      );

  final String id;
  final String kind;
  final String label;
  final int weight;
}

@immutable
final class GraphEdge {
  const GraphEdge({required this.a, required this.b, required this.weight});

  factory GraphEdge.fromJson(Map<String, dynamic> json) => GraphEdge(
        a: json['a'] as String,
        b: json['b'] as String,
        weight: (json['weight'] as num).toInt(),
      );

  final String a;
  final String b;
  final int weight;
}

@immutable
final class MemoryGraph {
  const MemoryGraph({required this.nodes, required this.edges});

  factory MemoryGraph.fromJson(Map<String, dynamic> json) => MemoryGraph(
        nodes: List.unmodifiable(
          (json['nodes'] as List<dynamic>? ?? const [])
              .map((node) => GraphNode.fromJson(node as Map<String, dynamic>)),
        ),
        edges: List.unmodifiable(
          (json['edges'] as List<dynamic>? ?? const [])
              .map((edge) => GraphEdge.fromJson(edge as Map<String, dynamic>)),
        ),
      );

  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
}
