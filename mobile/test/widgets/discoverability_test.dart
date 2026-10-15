import 'package:echo_app/models/voice.dart';
import 'package:echo_app/screens/home_screen.dart';
import 'package:echo_app/screens/settings/capabilities_screen.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/tip_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_memory_api.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a tip shows once: closing it is remembered', (tester) async {
    Future<void> pump() => tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: TipCard(tipKey: 't1', text: 'Try this')),
        ));
    await pump();
    await tester.pumpAndSettle();
    expect(find.text('Try this'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tip-close-t1')));
    await tester.pumpAndSettle();
    expect(find.text('Try this'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await pump();
    await tester.pumpAndSettle();
    expect(find.text('Try this'), findsNothing);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(TipCard.seenKey('t1')), isTrue);
  });

  testWidgets('a tip action does it and closes the tip', (tester) async {
    var done = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: TipCard(
            tipKey: 't2',
            text: 'Do it',
            actionLabel: 'Go',
            onAction: () => done++),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tip-action-t2')));
    await tester.pumpAndSettle();
    expect(done, 1);
    expect(find.text('Do it'), findsNothing);
  });

  testWidgets('an example from "What Echo can do" is asked in the chat',
      (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: CapabilitiesScreen(onAsk: asked.add),
    ));
    await tester.tap(find.text('What did I promise this week?'));
    await tester.pumpAndSettle();
    expect(asked, ['What did I promise this week?']);
  });

  testWidgets('Today suggests recording the own voice when there is none',
      (tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: HomeScreen(
          api: FakeTodayApi()
            ..voices =
                const VoiceProfiles(fingerprintsEnabled: true, items: []),
          deviceStatus: const DeviceStatus(
              connectionState: DeviceConnectionState.listening),
          setMuted: (_) async {},
          onOpenMemories: () {},
          onOpenTasks: () {},
          clock: () => DateTime(2026, 10, 15, 10),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tip-record_voice')), findsOneWidget);
  });
}
