import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/device_pill.dart';
import 'package:echo_app/widgets/echo_app_shell.dart';
import 'package:echo_app/widgets/echo_nav_bar.dart';
import 'package:echo_app/widgets/screen_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EchoNavBar', () {
    testWidgets('shows Today, Memories and the Ask button with semantics',
        (tester) async {
      await tester.pumpWidget(_themed(
        EchoNavBar(selectedIndex: 2, onSelect: (_) {}, onAskHold: (_) {}),
      ));

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Memories'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('echo-nav-2'))),
        matchesSemantics(
          label: 'Memories',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('echo-nav-1'))),
        matchesSemantics(
          label: 'Ask Echo',
          hint: 'Hold to dictate',
          isButton: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets('reports taps on every destination', (tester) async {
      final selected = <int>[];
      await tester.pumpWidget(_themed(
        EchoNavBar(selectedIndex: 0, onSelect: selected.add, onAskHold: (_) {}),
      ));

      await tester.tap(find.byKey(const Key('echo-nav-2')));
      await tester.tap(find.byKey(const Key('echo-ask-button')));
      await tester.tap(find.byKey(const Key('echo-nav-0')));
      expect(selected, [2, 1, 0]);
      for (final index in [0, 1, 2]) {
        final size = tester.getSize(find.byKey(Key('echo-nav-$index')));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      }
    });

    testWidgets('a held Ask button dictates until let go, without a tap',
        (tester) async {
      final holds = <bool>[];
      var taps = 0;
      await tester.pumpWidget(_themed(
        EchoNavBar(
          selectedIndex: 0,
          onSelect: (_) => taps++,
          onAskHold: holds.add,
        ),
      ));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('echo-ask-button'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(holds, isEmpty);
      await tester.pump(AskButton.holdAfter);
      expect(holds, [true]);

      await gesture.up();
      await tester.pump();
      expect(holds, [true, false]);
      expect(taps, 0);
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

      await tester.tap(find.byKey(const Key('echo-nav-2')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('echo-nav-0')));
      await tester.pump();

      expect(retainedKey.currentState, same(stateBeforeSwitch));
      expect(find.text('Count 1'), findsOneWidget);
      expect(retainedKey.currentState!.scrollOffset, greaterThan(0));
    });

    testWidgets(
        'tells the tabs how much the bar covers, and hides it for the '
        'keyboard', (tester) async {
      double? covered;
      Widget shell() => EchoAppShell(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            onAskHold: (_) {},
            children: [
              Builder(builder: (context) {
                covered = EchoShellInsets.bottomOf(context);
                return const SizedBox();
              }),
              const SizedBox(),
              const SizedBox(),
            ],
          );

      await tester.pumpWidget(_themed(shell()));
      expect(find.byType(EchoNavBar), findsOneWidget);
      expect(covered, greaterThan(EchoNavBar.barHeight));

      await tester.pumpWidget(_themed(
        MediaQuery(
          data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 300)),
          child: shell(),
        ),
      ));
      expect(find.byType(EchoNavBar), findsNothing);
      expect(covered, 0);
    });

    testWidgets('does not overflow at 320 width and 1.3 text scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_themed(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: EchoAppShell(
            selectedIndex: 1,
            dictating: true,
            onDestinationSelected: (_) {},
            onAskHold: (_) {},
            children: const [SizedBox(), SizedBox(), SizedBox()],
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('DevicePill', () {
    final cases = <DeviceConnectionState, String>{
      DeviceConnectionState.unpaired: 'Set up Echo',
      DeviceConnectionState.bluetoothOff: 'Bluetooth off',
      DeviceConnectionState.scanning: 'Connecting',
      DeviceConnectionState.connecting: 'Connecting',
      DeviceConnectionState.bonding: 'Connecting',
      DeviceConnectionState.listening: 'On',
      DeviceConnectionState.muted: 'Muted',
      DeviceConnectionState.reconnecting: 'Connecting',
      DeviceConnectionState.offline: 'Offline',
      DeviceConnectionState.error: 'Offline',
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key.name} reads "${entry.value}"', (tester) async {
        await tester.pumpWidget(_themed(
          DevicePill(status: _status(entry.key), onTap: () {}),
        ));
        expect(find.text(entry.value), findsOneWidget);
        expect(
          tester.getSemantics(find.byKey(const Key('device-pill'))),
          matchesSemantics(
            isButton: true,
            isLiveRegion: true,
            hasTapAction: true,
            label: _spoken[entry.key],
            hint: 'Opens settings',
          ),
        );
      });
    }

    testWidgets('shows the battery while listening', (tester) async {
      await tester.pumpWidget(_themed(
        const DevicePill(
          status: DeviceStatus(
            connectionState: DeviceConnectionState.listening,
            batteryPercent: 82,
          ),
        ),
      ));
      expect(find.text('82%'), findsOneWidget);
    });

    testWidgets('a tap opens settings; a long press mutes only when it can',
        (tester) async {
      var taps = 0;
      var holds = 0;
      Widget pill(DeviceConnectionState state) => _themed(
            DevicePill(
              status: _status(state),
              onTap: () => taps++,
              onLongPress: () => holds++,
            ),
          );

      await tester.pumpWidget(pill(DeviceConnectionState.listening));
      final pillFinder = find.byKey(const Key('device-pill'));
      expect(tester.getSize(pillFinder).height, greaterThanOrEqualTo(44));
      await tester.tap(pillFinder);
      await tester.longPress(pillFinder);
      expect((taps, holds), (1, 1));

      await tester.pumpWidget(pill(DeviceConnectionState.muted));
      await tester.longPress(pillFinder);
      expect(holds, 2);

      await tester.pumpWidget(pill(DeviceConnectionState.offline));
      await tester.longPress(pillFinder);
      expect(holds, 2);
    });

    testWidgets('fits a header at 320 width and 1.3 text scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final state in DeviceConnectionState.values) {
        await tester.pumpWidget(_themed(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: ScreenHeader(
              title: 'Ask',
              actions: [
                HeaderIconButton(
                  icon: Icons.history_rounded,
                  tooltip: 'Chat history',
                  onPressed: () {},
                ),
                HeaderIconButton(
                  icon: Icons.add_rounded,
                  tooltip: 'New chat',
                  onPressed: () {},
                ),
                DevicePill(status: _status(state), onTap: () {}),
              ],
            ),
          ),
        ));
        expect(tester.takeException(), isNull, reason: state.name);
      }
    });
  });
}

const _spoken = <DeviceConnectionState, String>{
  DeviceConnectionState.unpaired: 'No Echo paired',
  DeviceConnectionState.bluetoothOff: 'Bluetooth is off',
  DeviceConnectionState.scanning: 'Echo is connecting',
  DeviceConnectionState.connecting: 'Echo is connecting',
  DeviceConnectionState.bonding: 'Echo is connecting',
  DeviceConnectionState.listening: 'Echo is listening',
  DeviceConnectionState.muted: 'Echo is muted',
  DeviceConnectionState.reconnecting: 'Echo is connecting',
  DeviceConnectionState.offline: 'Echo is offline',
  DeviceConnectionState.error: 'Echo is offline',
};

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
      onDestinationSelected: (index) {
        setState(() => selectedIndex = index);
      },
      onAskHold: (_) {},
      children: [
        _RetainedTab(key: widget.retainedKey),
        const ColoredBox(color: Colors.red),
        const ColoredBox(color: Colors.green),
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
