import 'package:echo_app/models/memory_graph.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/screens/memory_graph_screen.dart';
import 'package:echo_app/screens/person_screen.dart';
import 'package:echo_app/screens/topic_conversations_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/radial_graph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  const graph = MemoryGraph(nodes: [
    GraphNode(id: 'you', kind: 'you', label: 'You', weight: 12),
    GraphNode(id: 'person:p1', kind: 'person', label: 'Marco', weight: 12),
    GraphNode(id: 't1', kind: 'topic', label: 'Atlas', weight: 4),
  ], edges: [
    GraphEdge(a: 'you', b: 'person:p1', weight: 12),
    GraphEdge(a: 'person:p1', b: 't1', weight: 4),
  ]);

  PersonDetail marco() => const PersonDetail(
        person: PersonSummary(id: 'p1', name: 'Marco'),
        conversations: [],
        tasks: [],
        events: [],
      );

  Future<void> pump(
    WidgetTester tester,
    FakeMemoryApi api, {
    Future<void> Function(String id)? onOpenPerson,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: MemoryGraphScreen(
        api: api,
        onOpenPerson: onOpenPerson ?? (_) async {},
        onOpenConversation: (_) async {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the map shows people and topics, and a tap opens the person',
      (tester) async {
    final api = FakeMemoryApi()
      ..memoryGraph = graph
      ..personDetails = {'p1': marco()};
    final openedPeople = <String>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (context) => MemoryGraphScreen(
          api: api,
          onOpenPerson: (id) {
            openedPeople.add(id);
            return Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => PersonScreen(personId: id, api: api),
              ),
            );
          },
          onOpenConversation: (_) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Marco'), findsOneWidget);
    expect(find.text('Atlas'), findsOneWidget);
    await tester.tap(find.byKey(const Key('graph-node-person:person:p1')));
    await tester.pumpAndSettle();
    expect(openedPeople, ['p1']);
    expect(find.byType(PersonScreen), findsOneWidget);
    expect(tester.widget<PersonScreen>(find.byType(PersonScreen)).personId, 'p1');
    expect(api.calls, contains('person p1'));
    expect(find.text('Person not found'), findsNothing);
  });

  testWidgets('a topic opens its filtered conversations', (tester) async {
    final api = FakeMemoryApi(
      conversations: [card('c1', startedAt: DateTime(2026, 11, 10), title: 'Atlas review')],
    )
      ..memoryGraph = graph
      ..topicConversations = {
        'Atlas': [card('c1', startedAt: DateTime(2026, 11, 10), title: 'Atlas review')],
      };
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('graph-node-topic:t1')));
    await tester.pumpAndSettle();

    expect(find.byType(TopicConversationsScreen), findsOneWidget);
    expect(find.text('Atlas review'), findsOneWidget);
    expect(api.calls, contains('list 30 0 topic=Atlas'));
  });

  testWidgets('the window chips ask for their selected ranges', (tester) async {
    final api = FakeMemoryApi()..memoryGraph = graph;
    await pump(tester, api);

    expect(api.calls, contains('graph 90'));
    await tester.tap(find.text('1 month'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('graph 30'));

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('graph 0'));
  });

  testWidgets('no people shows the empty state', (tester) async {
    final api = FakeMemoryApi()
      ..memoryGraph = const MemoryGraph(nodes: [
        GraphNode(id: 'you', kind: 'you', label: 'You', weight: 0),
      ], edges: []);
    await pump(tester, api);

    expect(find.text('Add people in People to see your map'), findsOneWidget);
  });

  testWidgets('Show as list gives screen-reader-friendly conversation counts',
      (tester) async {
    final api = FakeMemoryApi()..memoryGraph = graph;
    await pump(tester, api);

    await tester.tap(find.text('Show as list'));
    await tester.pumpAndSettle();

    expect(find.text('Marco · 12 conversations'), findsOneWidget);
    expect(find.text('Atlas · 4 conversations'), findsOneWidget);
  });

  testWidgets('tapping You does nothing', (tester) async {
    final api = FakeMemoryApi()..memoryGraph = graph;
    final openedPeople = <String>[];
    final openedConversations = <String>[];
    await pump(
      tester,
      api,
      onOpenPerson: (id) async => openedPeople.add(id),
    );

    await tester.tap(find.byKey(const Key('graph-node-you:you')));
    await tester.pumpAndSettle();

    expect(openedPeople, isEmpty);
    expect(openedConversations, isEmpty);
  });

  testWidgets('labels truncate visually but retain complete semantic labels',
      (tester) async {
    const fullLabel = 'An unusually long topic name that cannot fit';
    final api = FakeMemoryApi()
      ..memoryGraph = const MemoryGraph(nodes: [
        GraphNode(id: 'you', kind: 'you', label: 'You', weight: 12),
        GraphNode(id: 'person:p1', kind: 'person', label: 'Marco', weight: 12),
        GraphNode(id: 't1', kind: 'topic', label: fullLabel, weight: 4),
      ], edges: [
        GraphEdge(a: 'person:p1', b: 't1', weight: 4),
      ]);
    await pump(tester, api);

    final label = tester.widget<Text>(find.text(fullLabel));
    expect(label.maxLines, 1);
    expect(label.overflow, TextOverflow.ellipsis);
    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('$fullLabel, 4 conversations'),
      findsOneWidget,
    );
    // Disposed in the test: Flutter checks the handles before the tear-downs run
    semantics.dispose();
  });

  testWidgets('horizontal edge labels stay inside the map viewport',
      (tester) async {
    const rightLabel = 'B very long topic label near the right edge';
    const leftLabel = 'D very long topic label near the left edge';
    const edgeGraph = MemoryGraph(nodes: [
      GraphNode(id: 'you', kind: 'you', label: 'You', weight: 12),
      GraphNode(id: 'person:p1', kind: 'person', label: 'Marco', weight: 12),
      GraphNode(id: 'top', kind: 'topic', label: 'A top', weight: 4),
      GraphNode(id: 'right', kind: 'topic', label: rightLabel, weight: 4),
      GraphNode(id: 'bottom', kind: 'topic', label: 'C bottom', weight: 4),
      GraphNode(id: 'left', kind: 'topic', label: leftLabel, weight: 4),
    ], edges: []);
    final semantics = tester.ensureSemantics();
    await pump(tester, FakeMemoryApi()..memoryGraph = edgeGraph);

    final viewport = tester.getRect(find.byType(InteractiveViewer));
    final positions = radialLayout(edgeGraph, viewport.size);
    for (final entry in {'right': rightLabel, 'left': leftLabel}.entries) {
      expect(
        find.bySemanticsLabel('${entry.value}, 4 conversations'),
        findsOneWidget,
      );
      final target = tester.getRect(
        find.byKey(Key('graph-node-topic:${entry.key}')),
      );
      expect(target.width, 112);
      expect(
        target.topLeft + Offset(56, graphNodeSize(4) / 2),
        viewport.topLeft + positions[entry.key]!,
      );
      final label = tester.widget<Text>(find.text(entry.value));
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      final bounds = tester.getRect(find.text(entry.value));
      expect(bounds.left, greaterThanOrEqualTo(viewport.left));
      expect(bounds.right, lessThanOrEqualTo(viewport.right));
    }
    semantics.dispose();
  });
}
