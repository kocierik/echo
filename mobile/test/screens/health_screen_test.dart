import 'package:echo_app/screens/settings/health_screen.dart';
import 'package:echo_app/services/api/health_api.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Api implements HealthApi {
  _Api(this.days);

  List<HealthDayInfo> days;
  int keys = 0;
  bool forgot = false;

  @override
  Future<List<HealthDayInfo>> healthDays() async => days;

  @override
  Future<ShortcutKey> makeHealthKey() async {
    keys++;
    return (apiKey: 'key-$keys', path: '/api/health/day');
  }

  @override
  Future<void> forgetHealth() async {
    forgot = true;
    days = const [];
  }

  @override
  Future<String> getServerUrl() async => 'https://echo.test';
}

Future<void> _pump(WidgetTester tester, _Api api) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light, home: HealthScreen(api: api)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the days received, with sleep, steps and exercise', (tester) async {
    await _pump(
        tester,
        _Api([
          HealthDayInfo(
              day: DateTime(2026, 11, 5), sleepMinutes: 410, steps: 8421, exerciseMinutes: 32),
        ]));

    expect(find.byKey(const Key('health-day-2026-11-05')), findsOneWidget);
    expect(find.text('6 h 50'), findsOneWidget);
    expect(find.text('8421'), findsOneWidget);
    expect(find.text('32 min'), findsOneWidget);
  });

  testWidgets('the key for the shortcut, with the URL to post to', (tester) async {
    final api = _Api(const []);
    await _pump(tester, api);
    expect(find.byKey(const Key('health-empty')), findsOneWidget);

    await tester.tap(find.byKey(const Key('health-make-key')));
    await tester.pumpAndSettle();

    expect(find.text('https://echo.test/api/health/day'), findsOneWidget);
    expect(find.text('key-1'), findsOneWidget);

    // Another one asks first: the shortcut stops working until it gets the new one
    await tester.tap(find.text('New key'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'New key').last);
    await tester.pumpAndSettle();
    expect(find.text('key-2'), findsOneWidget);
  });

  testWidgets('Delete asks, then forgets the days and the key', (tester) async {
    final api = _Api([HealthDayInfo(day: DateTime(2026, 11, 5), steps: 100)]);
    await _pump(tester, api);

    await tester.tap(find.byKey(const Key('health-forget')));
    await tester.pumpAndSettle();
    expect(api.forgot, isFalse);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(api.forgot, isTrue);
    expect(find.byKey(const Key('health-empty')), findsOneWidget);
  });

  test('sleep reads as hours and minutes', () {
    expect(sleepText(410), '6 h 50');
    expect(sleepText(425), '7 h 05');
  });
}
