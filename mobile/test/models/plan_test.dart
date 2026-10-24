import 'package:echo_app/models/plan.dart';
import 'package:echo_app/utils/formatting.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> planJson({
  String plan = 'plus',
  int used = 12 * 3600,
  int monthly = 1500 * 60,
  int deferred = 0,
  bool over = false,
}) =>
    {
      'plan': plan,
      'monthly_seconds': monthly,
      'used_seconds': used,
      'daily_seconds': 600,
      'deferred_seconds': deferred,
      'resets_on': '2026-11-01',
      'over_budget': over,
      'web_searches_per_day': 30,
      'routines': 10,
    };

void main() {
  test('a plan from the server, with its name and this month\'s line', () {
    final plan = PlanInfo.fromJson(planJson());

    expect(plan.name, 'Plus');
    expect(plan.usageLine, '12 h of 25 h this month');
    expect(plan.resetsOn, DateTime(2026, 11, 1));
    expect(plan.dailySeconds, 600);
    expect(plan.webSearchesPerDay, 30);
    expect(plan.routines, 10);
    expect(plan.nearBudget, isFalse);
  });

  test('near the budget from 80%, not once it is used', () {
    expect(PlanInfo.fromJson(planJson(used: 20 * 3600)).nearBudget, isTrue);
    expect(PlanInfo.fromJson(planJson(used: 19 * 3600)).nearBudget, isFalse);
    expect(PlanInfo.fromJson(planJson(used: 25 * 3600, over: true)).nearBudget, isFalse);
  });

  test('speech in minutes, then hours (never more than was spoken)', () {
    expect(speechAmount(0), '0 min');
    expect(speechAmount(59), '0 min');
    expect(speechAmount(40 * 60), '40 min');
    expect(speechAmount(3600), '1 h');
    expect(speechAmount(2 * 3600 + 35 * 60), '2.5 h');
    expect(speechAmount(5 * 3600), '5 h');
    expect(speechAmount(12 * 3600 + 59 * 60), '12 h');
    expect(speechAmount(150 * 3600), '150 h');
  });

  test('a day and its month, for the reset', () {
    expect(dayAndMonth(DateTime(2026, 11, 1)), '1 November');
    expect(dayAndMonth(DateTime(2027, 1, 1)), '1 January');
  });
}
