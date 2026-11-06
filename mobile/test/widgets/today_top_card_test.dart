import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/today_top_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A Tuesday afternoon
  final now = DateTime(2026, 10, 20, 14, 20);
  PendingAction action(String id, DateTime expires) =>
      PendingAction(id: id, summary: 'Email Ada', status: 'pending', expiresAt: expires);

  group('pickMoment', () {
    test('only what needs the user: the action that expires first', () {
      final first = action('a1', now.add(const Duration(minutes: 9)));
      final soonest = action('a2', now.add(const Duration(minutes: 2)));

      final confirm = pickMoment(pending: [first, soonest]);
      expect(confirm, isA<ConfirmMoment>());
      expect((confirm as ConfirmMoment).action.id, 'a2'); // expires first
      expect(confirm.more, 1);

      expect(pickMoment(pending: const []), isNull);
    });

    test('a resolved action stays until reloaded, so its outcome shows', () {
      const done = PendingAction(id: 'a1', summary: 'Email Ada', status: 'executed');

      final moment = pickMoment(pending: const [done]);

      expect((moment as ConfirmMoment).action.id, 'a1');
      expect(moment.more, 0);
    });
  });

  testWidgets('an action to confirm, and how many more', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: TodayTopCard(
          moment: ConfirmMoment(action('a1', now), more: 2),
          busyIds: const {},
          onConfirm: (_) {},
          onCancel: (_) {},
          onMore: () {},
        ),
      ),
    ));

    expect(find.byKey(const Key('action-confirm-a1')), findsOneWidget);
    expect(find.text('+2 more'), findsOneWidget);
  });
}
