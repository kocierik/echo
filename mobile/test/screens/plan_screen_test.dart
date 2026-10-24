import 'package:echo_app/models/plan.dart';
import 'package:echo_app/screens/settings/plan_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../models/plan_test.dart' show planJson;

final class _PlanApi implements PlanApi {
  _PlanApi(this.result);

  final Object result;

  @override
  Future<PlanInfo> getPlan() async {
    if (result is PlanInfo) return result as PlanInfo;
    throw result;
  }
}

void main() {
  Future<void> pump(WidgetTester tester, Object result) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: PlanScreen(api: _PlanApi(result)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('within the budget: the plan, this month, the reset and what follows',
      (tester) async {
    await pump(tester, PlanInfo.fromJson(planJson()));

    expect(find.text('Plus'), findsOneWidget);
    expect(find.text('12 h of 25 h this month'), findsOneWidget);
    expect(find.text('Starts again on 1 November.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('The first 10 minutes of each day'), findsOneWidget);
    expect(find.text('25 h a month'), findsOneWidget);
    expect(find.text('30 a day'), findsOneWidget);
    expect(find.text('Up to 10'), findsOneWidget);
    expect(find.text('Plans cannot be changed in the app yet.'), findsOneWidget);
    expect(find.textContaining('This month\'s speech is used'), findsNothing);
    expect(find.textContaining('waiting'), findsNothing);
  });

  testWidgets('past the budget, with speech waiting', (tester) async {
    await pump(
      tester,
      PlanInfo.fromJson(planJson(
        plan: 'free',
        monthly: 300 * 60,
        used: 300 * 60,
        deferred: 3 * 3600,
        over: true,
      )),
    );

    expect(find.text('Free'), findsOneWidget);
    expect(find.text('5 h of 5 h this month'), findsOneWidget);
    expect(
      find.text('This month\'s speech is used. Echo is transcribing 10 minutes a day '
          'until 1 November.'),
      findsOneWidget,
    );
    expect(find.text('3 h of speech waiting: Echo transcribes it from 1 November.'),
        findsOneWidget);
  });

  testWidgets('a failure says so', (tester) async {
    await pump(tester, Exception('offline'));

    expect(find.text('Echo could not load the plan. Check the connection and try again.'),
        findsOneWidget);
  });
}
