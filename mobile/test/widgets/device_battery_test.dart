import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/device_card.dart';
import 'package:echo_app/widgets/privacy_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _card({int? battery}) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: DeviceCard(
          presentation: PrivacyControlPresentation.listening,
          batteryPercent: battery,
        ),
      ),
    );

void main() {
  testWidgets('the device card shows the battery when the wearable measures it', (tester) async {
    await tester.pumpWidget(_card(battery: 72));

    expect(find.byKey(const Key('device-battery')), findsOneWidget);
    expect(find.text('72%'), findsOneWidget);
    expect(find.byIcon(Icons.battery_5_bar_rounded), findsOneWidget);
  });

  testWidgets('no battery on the card when it is unknown', (tester) async {
    await tester.pumpWidget(_card());
    expect(find.byKey(const Key('device-battery')), findsNothing);
  });

  test('a low battery gets the alert icon', () {
    expect(batteryIcon(10), Icons.battery_alert_rounded);
    expect(batteryIcon(95), Icons.battery_full_rounded);
  });
}
