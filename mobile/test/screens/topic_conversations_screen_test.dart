import 'package:echo_app/screens/topic_conversations_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  testWidgets('lists the topic-filtered conversations and opens one',
      (tester) async {
    final api = FakeMemoryApi()
      ..topicConversations = {
        'Atlas': [
          card(
            'c1',
            startedAt: DateTime(2026, 11, 10, 9),
            title: 'Atlas review',
            summary: 'The new design.',
          ),
        ],
      };
    final opened = <String>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: TopicConversationsScreen(
        topic: 'Atlas',
        api: api,
        onOpenConversation: (id) async => opened.add(id),
      ),
    ));
    await tester.pumpAndSettle();

    expect(api.calls, contains('list 30 0 topic=Atlas'));
    // The large title and the collapsed bar both carry it
    expect(find.text('Atlas'), findsWidgets);
    expect(find.text('Atlas review'), findsOneWidget);
    expect(find.text('The new design.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('conversation-c1')));
    await tester.pumpAndSettle();
    expect(opened, ['c1']);
  });
}
