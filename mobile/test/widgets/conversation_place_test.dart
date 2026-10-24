import 'package:echo_app/models/place.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/conversation_card.dart';
import 'package:echo_app/widgets/today_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  const mario = ConversationPlace(visitId: 'v1', name: 'Trattoria da Mario', address: 'Via Roma 12');
  final dinner = card(
    'c1',
    startedAt: DateTime(2026, 10, 17, 20, 10),
    title: 'Cena con Marco',
    people: const ['Marco'],
    place: mario,
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Your day reads as conversations and their places', (tester) async {
    await pump(
      tester,
      YourDayPanel(
        loading: false,
        conversations: [
          dinner,
          // Short and with nobody: one line, and no place to say
          card('c2', startedAt: DateTime(2026, 10, 17, 9), people: const [], taskCount: 0,
              duration: const Duration(minutes: 3), title: 'Quick note'),
        ],
        error: null,
        recording: false,
        onRetry: () {},
        onOpen: (_) {},
        onSeeAll: () {},
      ),
    );

    expect(find.textContaining('Trattoria da Mario'), findsOneWidget);
    expect(find.text('Quick note'), findsOneWidget);
  });

  testWidgets('a conversation card and a day row show the place', (tester) async {
    await pump(
      tester,
      Column(children: [
        ConversationCardTile(conversation: dinner, onTap: () {}),
        ConversationRow(conversation: dinner, onTap: () {}),
        ConversationCardTile(
          conversation: card('c3', startedAt: DateTime(2026, 10, 17, 9)),
          onTap: () {},
        ),
      ]),
    );

    expect(find.text('Trattoria da Mario'), findsNWidgets(2));
    expect(
      tester.getSemantics(find.byKey(const Key('conversation-c1')).first).label,
      contains('At Trattoria da Mario'),
    );
  });
}
