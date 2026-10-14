import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/device_status_strip.dart';
import 'package:echo_app/widgets/echo_app_shell.dart';
import 'package:echo_app/widgets/echo_bottom_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EchoBottomNavigation', () {
    testWidgets('shows stable labeled destinations and selected semantics',
        (tester) async {
      await tester.pumpWidget(_themed(
        EchoBottomNavigation(
          selectedIndex: 1,
          onDestinationSelected: (_) {},
        ),
      ));

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Memories'), findsOneWidget);
      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('Ask'), findsOneWidget);
      expect(find.byIcon(Icons.home_rounded), findsOneWidget);
      expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('echo-nav-1'))),
        matchesSemantics(
          label: 'Memories',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets('reports destination changes without shifting tracks',
        (tester) async {
      int? selected;
      await tester.pumpWidget(_themed(
        EchoBottomNavigation(
          selectedIndex: 0,
          onDestinationSelected: (index) => selected = index,
        ),
      ));

      final widths = List.generate(
        4,
        (index) => tester.getSize(find.byKey(Key('echo-nav-$index'))).width,
      );
      expect(widths[0], widths[1]);
      expect(widths[1], widths[2]);
      expect(widths[2], widths[3]);

      await tester.tap(find.byKey(const Key('echo-nav-3')));
      expect(selected, 3);
    });
  });

  group('EchoAppShell', () {
    testWidgets('retains child counter and scroll state across destinations',
        (tester) async {
      final retainedKey = GlobalKey<_RetainedTabState>();
      await tester.pumpWidget(_themed(
        _ShellHost(retainedKey: retainedKey),
      ));

      await tester.tap(find.text('Increment'));
      await tester.drag(
        find.byKey(const PageStorageKey('retained-scroll')),
        const Offset(0, -240),
      );
      await tester.pump();
      final stateBeforeSwitch = retainedKey.currentState;
      expect(stateBeforeSwitch!.count, 1);
      expect(stateBeforeSwitch.scrollOffset, greaterThan(0));

      await tester.tap(find.byKey(const Key('echo-nav-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('echo-nav-0')));
      await tester.pump();

      expect(retainedKey.currentState, same(stateBeforeSwitch));
      expect(find.text('Count 1'), findsOneWidget);
      expect(retainedKey.currentState!.scrollOffset, greaterThan(0));
    });

    testWidgets('exposes the settings callback through a 44 point control',
        (tester) async {
      var settingsTaps = 0;
      await tester.pumpWidget(_themed(
        EchoAppShell(
          selectedIndex: 0,
          status: _status(DeviceConnectionState.listening),
          onDestinationSelected: (_) {},
          onSettingsTap: () => settingsTaps++,
          children: const [
            SizedBox(),
            SizedBox(),
            SizedBox(),
            SizedBox(),
          ],
        ),
      ));

      final settings = find.byTooltip('Settings');
      expect(settings, findsOneWidget);
      expect(tester.getSize(settings).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(settings).height, greaterThanOrEqualTo(44));
      await tester.tap(settings);
      expect(settingsTaps, 1);
    });

    testWidgets('keeps 56 point status and 64 point safe navigation geometry',
        (tester) async {
      // At ratio 1 the 20 pixel inset is 20 points
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.padding = const FakeViewPadding(bottom: 20);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(_themed(
        EchoAppShell(
          selectedIndex: 0,
          status: _status(DeviceConnectionState.listening),
          onDestinationSelected: (_) {},
          onSettingsTap: () {},
          children: const [
            SizedBox(),
            SizedBox(),
            SizedBox(),
            SizedBox(),
          ],
        ),
      ));

      expect(tester.getSize(find.byType(DeviceStatusStrip)).height, 56);
      expect(
        tester.getSize(find.byType(EchoBottomNavigation)).height,
        84,
      );
      for (var index = 0; index < 4; index++) {
        expect(
          tester.getSize(find.byKey(Key('echo-nav-$index'))).height,
          greaterThanOrEqualTo(44),
        );
      }
    });
  });

  group('DeviceStatusStrip', () {
    final cases = <DeviceConnectionState, String>{
      DeviceConnectionState.unpaired: 'Set up wearable',
      DeviceConnectionState.bluetoothOff: 'Bluetooth is off',
      DeviceConnectionState.scanning: 'Finding Echo',
      DeviceConnectionState.connecting: 'Connecting',
      DeviceConnectionState.bonding: 'Securing connection',
      DeviceConnectionState.listening: 'Listening',
      DeviceConnectionState.muted: 'Muted',
      DeviceConnectionState.reconnecting: 'Reconnecting',
      DeviceConnectionState.offline: 'Echo offline',
      DeviceConnectionState.error: 'Pairing failed',
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key.name} has approved copy and live semantics',
          (tester) async {
        await tester.pumpWidget(_themed(
          DeviceStatusStrip(
            status: DeviceStatus(
              connectionState: entry.key,
              error: entry.key == DeviceConnectionState.error
                  ? 'Pairing failed'
                  : null,
            ),
          ),
        ));

        expect(find.text(entry.value), findsOneWidget);
        expect(
          tester.getSemantics(
            find.byKey(const Key('device-status-semantics')),
          ),
          matchesSemantics(
            label: 'Device status: ${entry.value}',
            isLiveRegion: true,
          ),
        );
      });
    }

    testWidgets('uses an error fallback and distinct listening and mute cues',
        (tester) async {
      await tester.pumpWidget(_themed(
        DeviceStatusStrip(status: _status(DeviceConnectionState.error)),
      ));
      expect(find.text('Connection error'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);

      await tester.pumpWidget(_themed(
        DeviceStatusStrip(status: _status(DeviceConnectionState.listening)),
      ));
      expect(find.byIcon(Icons.hearing_rounded), findsOneWidget);
      final listeningColor = _statusText(tester, 'Listening').style!.color;

      await tester.pumpWidget(_themed(
        DeviceStatusStrip(status: _status(DeviceConnectionState.muted)),
      ));
      expect(find.byIcon(Icons.privacy_tip_outlined), findsOneWidget);
      final mutedColor = _statusText(tester, 'Muted').style!.color;
      expect(listeningColor, EchoPalette.dark.green);
      expect(mutedColor, EchoPalette.dark.red);
      expect(mutedColor, isNot(listeningColor));
    });

    testWidgets('only renders a tappable chevron when callback is provided',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_themed(
        DeviceStatusStrip(status: _status(DeviceConnectionState.offline)),
      ));
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.byKey(const Key('device-status-action')), findsNothing);

      await tester.pumpWidget(_themed(
        DeviceStatusStrip(
          status: _status(DeviceConnectionState.offline),
          onTap: () => taps++,
        ),
      ));
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      final action = find.byKey(const Key('device-status-action'));
      expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
      await tester.tap(action);
      expect(taps, 1);
    });

    testWidgets('does not overflow at 320 width and 1.3 text scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final state in DeviceConnectionState.values) {
        await tester.pumpWidget(_themed(
          MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(1.3),
            ),
            child: DeviceStatusStrip(
              status: DeviceStatus(
                connectionState: state,
                error: state == DeviceConnectionState.error
                    ? 'A very long connection error that must stay contained'
                    : null,
              ),
              onTap: () {},
            ),
          ),
        ));
        expect(tester.takeException(), isNull, reason: state.name);
      }

      await tester.pumpWidget(_themed(
        MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(1.3),
          ),
          child: EchoAppShell(
            selectedIndex: 0,
            status: const DeviceStatus(
              connectionState: DeviceConnectionState.bonding,
            ),
            onStatusTap: () {},
            onDestinationSelected: (_) {},
            onSettingsTap: () {},
            children: const [
              SizedBox(),
              SizedBox(),
              SizedBox(),
              SizedBox(),
            ],
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });
}

Widget _themed(Widget child) {
  return MaterialApp(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: ThemeMode.dark,
    home: Scaffold(body: child),
  );
}

DeviceStatus _status(DeviceConnectionState state) {
  return DeviceStatus(connectionState: state);
}

Text _statusText(WidgetTester tester, String copy) {
  return tester.widget<Text>(find.text(copy));
}

final class _ShellHost extends StatefulWidget {
  const _ShellHost({required this.retainedKey});

  final GlobalKey<_RetainedTabState> retainedKey;

  @override
  State<_ShellHost> createState() => _ShellHostState();
}

final class _ShellHostState extends State<_ShellHost> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return EchoAppShell(
      selectedIndex: selectedIndex,
      status: _status(DeviceConnectionState.listening),
      onDestinationSelected: (index) {
        setState(() => selectedIndex = index);
      },
      onSettingsTap: () {},
      children: [
        _RetainedTab(key: widget.retainedKey),
        const ColoredBox(color: Colors.red),
        const ColoredBox(color: Colors.green),
        const ColoredBox(color: Colors.blue),
      ],
    );
  }
}

final class _RetainedTab extends StatefulWidget {
  const _RetainedTab({super.key});

  @override
  State<_RetainedTab> createState() => _RetainedTabState();
}

final class _RetainedTabState extends State<_RetainedTab> {
  final scrollController = ScrollController();
  int count = 0;
  double get scrollOffset => scrollController.offset;

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          onPressed: () => setState(() => count++),
          child: const Text('Increment'),
        ),
        Text('Count $count'),
        Expanded(
          child: ListView.builder(
            key: const PageStorageKey('retained-scroll'),
            controller: scrollController,
            itemExtent: 48,
            itemCount: 40,
            itemBuilder: (context, index) => Text('Item $index'),
          ),
        ),
      ],
    );
  }
}