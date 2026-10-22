import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/today_top_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  // A Tuesday afternoon
  final now = DateTime(2026, 10, 20, 14, 20);
  final standup = card('standup',
      startedAt: DateTime(2026, 10, 20, 9, 10),
      title: 'Stand-up with Marco',
      duration: const Duration(minutes: 25),
      people: const ['Marco']);
  final lunch = card('lunch',
      startedAt: DateTime(2026, 10, 20, 12, 30),
      title: 'Lunch with Ada',
      duration: const Duration(hours: 1),
      people: const ['Ada', 'Luca']);
  final call = card('call',
      startedAt: DateTime(2026, 10, 20, 13, 30),
      title: 'The Atlas call',
      duration: const Duration(minutes: 45),
      people: const ['Marco']);
  final quick = card('quick',
      startedAt: DateTime(2026, 10, 20, 13, 0),
      title: 'Coffee',
      duration: const Duration(minutes: 3),
      people: const []);
  final open = card('open',
      startedAt: DateTime(2026, 10, 20, 14, 8), title: null, isOpen: true, people: const ['Marco']);
  final review = ComingUp(title: 'Review with Ada', start: DateTime(2026, 10, 20, 15), recap: 'Last time: the budget');
  PendingAction action(String id, DateTime expires) =>
      PendingAction(id: id, summary: 'Email Ada', status: 'pending', expiresAt: expires);

  group('pickMoment', () {
    test('the first that applies: confirm, coming up, now, so far today', () {
      final today = [open, call, lunch, standup];
      final first = action('a1', now.add(const Duration(minutes: 9)));
      final soonest = action('a2', now.add(const Duration(minutes: 2)));

      final confirm = pickMoment(
          pending: [first, soonest], comingUp: review, open: open, today: today, now: now);
      expect(confirm, isA<ConfirmMoment>());
      expect((confirm as ConfirmMoment).action.id, 'a2'); // expires first
      expect(confirm.more, 1);

      expect(pickMoment(pending: const [], comingUp: review, open: open, today: today, now: now),
          isA<ComingUpMoment>());
      final live = pickMoment(pending: const [], open: open, lastLine: 'so we move it', today: today, now: now);
      expect(live, isA<NowMoment>());
      expect((live as NowMoment).lastLine, 'so we move it');

      final soFar = pickMoment(pending: const [], today: [call, lunch, standup], now: now);
      expect(soFar, isA<SoFarMoment>());
      soFar as SoFarMoment;
      expect(soFar.conversations, 3);
      expect(soFar.talked, const Duration(hours: 2, minutes: 10));
      expect(soFar.people, 3);

      expect(pickMoment(pending: const [], today: const [], now: now), isNull);
    });

    test('a resolved action stays until reloaded, so its outcome shows', () {
      const done = PendingAction(id: 'a1', summary: 'Email Ada', status: 'executed');

      final moment = pickMoment(pending: const [done], today: const [], now: now);

      expect((moment as ConfirmMoment).action.id, 'a1');
      expect(moment.more, 0);
    });
  });

  test('the greeting has the name only when there is one', () {
    expect(greeting(DateTime(2026, 10, 20, 9), 'Erik'), 'Good morning, Erik');
    expect(greeting(DateTime(2026, 10, 20, 14), 'Erik'), 'Good afternoon, Erik');
    expect(greeting(DateTime(2026, 10, 20, 19), null), 'Good evening');
    expect(greeting(DateTime(2026, 10, 20, 2), '  '), 'Good evening');
  });

  test('so far today names the longest conversations in time order', () {
    expect(soFarLine([call, quick, lunch, standup]),
        'Stand-up with Marco, Lunch with Ada, The Atlas call.');
    expect(soFarLine([lunch]), 'Lunch with Ada.');
  });

  testWidgets('each moment reads as drawn', (tester) async {
    Future<void> show(TodayMoment moment) => tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: TodayTopCard(
              moment: moment,
              now: now,
              busyIds: const {},
              onConfirm: (_) {},
              onCancel: (_) {},
              onMore: () {},
              onOpenConversation: (_) {},
            ),
          ),
        ));

    await show(ComingUpMoment(review));
    expect(find.text('COMING UP · 15:00'), findsOneWidget);
    expect(find.text('Review with Ada'), findsOneWidget);
    expect(find.text('Last time: the budget'), findsOneWidget);

    await show(NowMoment(open, lastLine: 'so we move the demo'));
    expect(find.text('NOW · 12 MIN'), findsOneWidget);
    expect(find.text('with Marco'), findsOneWidget);
    expect(find.text('"…so we move the demo…"'), findsOneWidget);

    await show(const SoFarMoment(
      line: 'Stand-up with Marco, Lunch with Ada.',
      conversations: 2,
      talked: Duration(hours: 1, minutes: 25),
      people: 3,
    ));
    expect(find.text('SO FAR TODAY'), findsOneWidget);
    expect(find.text('2 conversations'), findsOneWidget);
    expect(find.text('1 h 25 min of talk'), findsOneWidget);
    expect(find.text('3 people'), findsOneWidget);

    await show(ConfirmMoment(action('a1', now), more: 2));
    expect(find.byKey(const Key('action-confirm-a1')), findsOneWidget);
    expect(find.text('+2 more'), findsOneWidget);
  });
}
