import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/device_instrument.dart';
import 'package:echo_app/widgets/device_readings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _panel(DeviceStatus status, {ValueChanged<bool>? onMute}) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: DeviceInstrumentPanel(status: status, onDetails: () {}, onMute: onMute),
      ),
    );

void main() {
  testWidgets('the panel shows the battery when the wearable measures it', (tester) async {
    await tester.pumpWidget(_panel(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      batteryPercent: 72,
    )));
    expect(find.text('Battery'), findsOneWidget);
    expect(find.text('72%'), findsOneWidget);

    await tester.pumpWidget(_panel(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
    )));
    expect(find.text('Battery'), findsNothing);
  });

  test('speech waiting on the wearable is told in seconds or minutes', () {
    expect(pendingSpeechLabel(8 * 1024 * 5), isNull);
    expect(pendingSpeechLabel(8 * 1024 * 40), '40 s of speech to sync');
    expect(pendingSpeechLabel(8 * 1024 * 150), '3 min of speech to sync');
  });

  testWidgets('the panel says how much speech is waiting', (tester) async {
    await tester.pumpWidget(_panel(const DeviceStatus(
      connectionState: DeviceConnectionState.offline,
      bufferBytes: 8 * 1024 * 120,
    )));
    expect(find.text('2 min of speech to sync'), findsOneWidget);
  });

  testWidgets('muting while listening, listening again while muted', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(_panel(
      const DeviceStatus(connectionState: DeviceConnectionState.listening),
      onMute: calls.add,
    ));
    await tester.tap(find.text('Mute Echo'));

    await tester.pumpWidget(_panel(
      const DeviceStatus(connectionState: DeviceConnectionState.muted),
      onMute: calls.add,
    ));
    await tester.tap(find.text('Listen again'));
    expect(calls, [true, false]);
  });

  test('a low battery gets the alert icon', () {
    expect(batteryIcon(10), Icons.battery_alert_rounded);
    expect(batteryIcon(95), Icons.battery_full_rounded);
  });
}
