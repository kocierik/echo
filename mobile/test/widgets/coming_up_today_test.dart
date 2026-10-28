import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/coming_up_today.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _event(String title, DateTime start, {bool allDay = false}) => {
      'id': title,
      'title': title,
      'start': start.toUtc().toIso8601String(),
      'all_day': allDay,
    };

void main() {
  final now = DateTime(2026, 10, 28, 10, 30);

  test('past events are left out, all-day first', () {
    final events = TodayEvent.fromPhone([
      _event('Dentist', DateTime(2026, 10, 28, 15)),
      _event('Stand-up', DateTime(2026, 10, 28, 9)),
      _event('Holiday', DateTime(2026, 10, 28), allDay: true),
      _event('Lunch with Ada', DateTime(2026, 10, 28, 12, 30)),
      _event('Tomorrow', DateTime(2026, 10, 29, 9)),
      {'title': '', 'start': 'x'},
    ], now);

    expect(events.map((e) => e.title), ['Holiday', 'Lunch with Ada', 'Dentist']);
    expect(events.first.allDay, isTrue);
    expect(events[1].start, DateTime(2026, 10, 28, 12, 30));
  });

  Future<void> pump(WidgetTester tester, List<TodayEvent> events, {ComingUp? recap}) =>
      tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(child: ComingUpTodayPanel(events: events, recap: recap)),
        ),
      ));

  testWidgets('each event with its time, all-day ones as All day', (tester) async {
    await pump(tester, [
      TodayEvent(title: 'Holiday', start: DateTime(2026, 10, 28), allDay: true),
      TodayEvent(title: 'Dentist', start: DateTime(2026, 10, 28, 15)),
    ]);

    expect(find.text('Coming up today'), findsOneWidget);
    expect(find.text('All day'), findsOneWidget);
    expect(find.text('15:00'), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
  });

  testWidgets('the recap shows under its event', (tester) async {
    final long = 'Last time: the budget, the November date and who signs the contract. ' * 4;
    await pump(
      tester,
      [
        TodayEvent(title: 'Call with Marco', start: DateTime(2026, 10, 28, 11)),
        TodayEvent(title: 'Dentist', start: DateTime(2026, 10, 28, 15)),
      ],
      recap: ComingUp(title: 'Call with Marco', start: DateTime(2026, 10, 28, 11), recap: long),
    );

    expect(find.text(long), findsOneWidget);
    expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
    expect(
      tester.getTopLeft(find.text(long)).dy,
      lessThan(tester.getTopLeft(find.text('Dentist')).dy),
    );
  });

  testWidgets('no events, no panel', (tester) async {
    await pump(tester, const []);

    expect(find.byKey(const Key('coming-up-today')), findsNothing);
  });
}
