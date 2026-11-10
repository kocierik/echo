import 'dart:async';

import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/session_state.dart';
import 'package:echo_app/screens/echo_device_screen.dart';
import 'package:echo_app/services/app/app_controller.dart';
import 'package:echo_app/services/device/device_ble_port.dart';
import 'package:echo_app/services/device/device_controller.dart';
import 'package:echo_app/services/device/device_identity_store.dart';
import 'package:echo_app/services/device/device_protocol.dart';
import 'package:echo_app/services/onboarding/onboarding_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders listening muted connecting and offline truthfully',
      (tester) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    for (final entry in const {
      DeviceConnectionState.listening: 'Listening',
      DeviceConnectionState.muted: 'Muted',
      DeviceConnectionState.connecting: 'Connecting',
      DeviceConnectionState.offline: 'Offline',
    }.entries) {
      fixture.emit(DeviceStatus(connectionState: entry.key));
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget);
    }
  });

  testWidgets('is the Echo screen, built around the instrument: Mute Echo mutes',
      (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        firmwareVersion: '0.5.1',
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    expect(find.text('Echo'), findsOneWidget);
    expect(find.byKey(const Key('device-instrument')), findsOneWidget);
    // Already here: no way to "Device details"
    expect(find.byKey(const Key('device-details')), findsNothing);
    expect(find.text('Forget device'), findsOneWidget);
    expect(find.text('0.5.1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-instrument-action')));
    await tester.pump();
    expect(fixture.ble.mutes, [true]);
  });

  testWidgets('says an unknown battery is not measured and shows a known one',
      (tester) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    expect(find.text('Battery'), findsOneWidget);
    expect(find.text('Not measured'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);

    fixture.emit(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      batteryPercent: 73,
    ));
    await tester.pump();
    expect(find.text('Battery'), findsOneWidget);
    expect(find.text('73%'), findsOneWidget);
  });

  testWidgets('the microphone gain is set from the phone, with firmware 0.9.3 on', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        firmwareVersion: '0.9.3',
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    final slider = find.byKey(const Key('device-mic-gain'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    await tester.drag(slider, const Offset(600, 0));
    await tester.pumpAndSettle();

    expect(fixture.ble.micGains, [8]);
    expect((await SharedPreferences.getInstance()).getInt('echo_mic_gain'), 8);
  });

  testWidgets('older firmware has no microphone gain', (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        firmwareVersion: '0.9.2',
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    expect(find.byKey(const Key('device-mic-gain')), findsNothing);
  });

  testWidgets('shows buffer loss firmware and protocol from status',
      (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        protocolVersion: 2,
        firmwareVersion: '1.4.7',
        bufferCount: 3,
        bufferBytes: 12000,
        droppedSegments: 7,
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    expect(find.text('Protocol'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Firmware'), findsOneWidget);
    expect(find.text('1.4.7'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('12000'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('the microSD: its room and the speech waiting on it, or no card',
      (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        protocolVersion: 5,
        microSd: MicroSd(inUse: true, totalMb: 30436, freeMb: 29802, pendingKb: 5760),
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    expect(find.byKey(const Key('device-microsd')), findsOneWidget);
    expect(find.text('29.1 GB free of 29.7 GB · 12 min of speech on it'), findsOneWidget);
  });

  testWidgets('without a card it says so; older firmware shows no microSD row',
      (tester) async {
    final none = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        protocolVersion: 5,
        microSd: MicroSd(inUse: false, totalMb: 0, freeMb: 0, pendingKb: 0),
      ),
    );
    addTearDown(none.dispose);
    await none.pump(tester);
    expect(find.textContaining('No card'), findsOneWidget);

    final older = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        protocolVersion: 4,
      ),
    );
    addTearDown(older.dispose);
    await older.pump(tester);
    expect(find.byKey(const Key('device-microsd')), findsNothing);
  });

  testWidgets('offline reconnect delegates to DeviceController', (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.offline,
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);
    final schedulesBefore = fixture.scheduler.schedules;

    await tester.tap(find.byKey(const Key('device-reconnect')));
    await tester.pump();

    expect(fixture.scheduler.schedules, schedulesBefore + 1);
  });

  testWidgets('an unpaired app offers pairing, which reopens the onboarding',
      (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.unpaired,
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    await tester.tap(find.byKey(const Key('device-pair')));
    await tester.pump();

    expect(fixture.onboardingCallbacks, 1);
    expect(fixture.forgotCallbacks, 0);
    expect(
      fixture.preferences.getBool(OnboardingController.completedKey),
      isTrue,
    );
  });

  testWidgets('a paired device offers no pairing action', (tester) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    expect(find.byKey(const Key('device-pair')), findsNothing);
  });

  testWidgets('forget cancel leaves identity and callbacks untouched',
      (tester) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.pump(tester);

    await tester.tap(find.text('Forget device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(fixture.store.value, 'saved-echo');
    expect(fixture.forgotCallbacks, 0);
    expect(fixture.onboardingCallbacks, 0);
  });

  testWidgets('forget waits for ACK then clears onboarding and invokes callbacks',
      (tester) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final forgotten = Completer<void>();
    fixture.ble.forgetCompleter = forgotten;
    await fixture.pump(tester);

    await tester.tap(find.text('Forget device'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget device'));
    await tester.pump();

    expect(fixture.forgotCallbacks, 0);
    expect(fixture.onboardingCallbacks, 0);
    expect(
      fixture.preferences.getBool(OnboardingController.completedKey),
      isTrue,
    );

    forgotten.complete();
    // The screen is the first route here, so the success pop leaves its spinner
    // running and pumpAndSettle would never return
    await tester.pump(const Duration(seconds: 1));

    expect(fixture.store.value, isNull);
    expect(
      fixture.preferences.containsKey(OnboardingController.completedKey),
      isFalse,
    );
    expect(
      fixture.preferences.containsKey(OnboardingController.highestStepKey),
      isFalse,
    );
    expect(fixture.forgotCallbacks, 1);
    expect(fixture.onboardingCallbacks, 1);
  });

  testWidgets('forget failure preserves identity and exposes a working retry',
      (tester) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    fixture.ble.forgetFailures = 1;
    await fixture.pump(tester);

    await tester.tap(find.text('Forget device'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget device'));
    await tester.pumpAndSettle();

    expect(fixture.store.value, 'saved-echo');
    expect(find.byKey(const Key('device-action-error')), findsOneWidget);
    expect(find.text('Forget device'), findsOneWidget);
    expect(fixture.forgotCallbacks, 0);

    await tester.tap(find.text('Forget device'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget device'));
    // The screen is the first route here, so the success pop leaves its spinner
    // running and pumpAndSettle would never return
    await tester.pump(const Duration(seconds: 1));
    expect(fixture.store.value, isNull);
    expect(fixture.forgotCallbacks, 1);
  });

  testWidgets('fits 320 width at text scale 1.3 in light and dark themes',
      (tester) async {
    final fixture = await _Fixture.create(
      initialStatus: const DeviceStatus(
        connectionState: DeviceConnectionState.offline,
        batteryPercent: 100,
        protocolVersion: 2,
        firmwareVersion: '12.34.56',
        bufferCount: 999,
        bufferBytes: 999999,
        droppedSegments: 999,
      ),
    );
    addTearDown(fixture.dispose);
    tester.view.physicalSize = const Size(320, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await fixture.pump(tester, theme: theme, textScale: 1.3);
      expect(tester.takeException(), isNull);
    }
  });
}

final class _Fixture {
  _Fixture._({
    required this.preferences,
    required this.states,
    required this.appController,
    required this.deviceController,
    required this.ble,
    required this.store,
    required this.scheduler,
  });

  final SharedPreferences preferences;
  final StreamController<DeviceStatus> states;
  final AppController appController;
  final DeviceController deviceController;
  final _FakeBlePort ble;
  final _FakeIdentityStore store;
  final _FakeScheduler scheduler;
  int forgotCallbacks = 0;
  int onboardingCallbacks = 0;

  static Future<_Fixture> create({
    DeviceStatus initialStatus = const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
    ),
  }) async {
    SharedPreferences.setMockInitialValues({
      OnboardingController.completedKey: true,
      OnboardingController.highestStepKey: 3,
    });
    final preferences = await SharedPreferences.getInstance();
    final states = StreamController<DeviceStatus>.broadcast(sync: true);
    final appController = AppController(
      initialDevice: initialStatus,
      deviceStates: states.stream,
      initialSession: const SessionState(SessionStatus.loggedIn),
      sessionStates: const Stream.empty(),
      preferences: SharedPreferencesAppPreferences(preferences),
    );
    await appController.initialize();
    final ble = _FakeBlePort();
    final store = _FakeIdentityStore('saved-echo');
    final scheduler = _FakeScheduler();
    final deviceController = DeviceController(
      ble: ble,
      identityStore: store,
      scheduleRetry: scheduler.schedule,
    );
    await deviceController.start();
    return _Fixture._(
      preferences: preferences,
      states: states,
      appController: appController,
      deviceController: deviceController,
      ble: ble,
      store: store,
      scheduler: scheduler,
    );
  }

  void emit(DeviceStatus status) => states.add(status);

  Future<void> pump(
    WidgetTester tester, {
    ThemeData? theme,
    double textScale = 1,
  }) async {
    // Tall enough for every row: the list builds only what is on screen
    // (unless the test chose a size of its own)
    if (tester.view.devicePixelRatio != 1) {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: EchoDeviceScreen(
          appController: appController,
          deviceController: deviceController,
          resetOnboarding: () async {
            await preferences.remove(OnboardingController.completedKey);
            await preferences.remove(OnboardingController.highestStepKey);
          },
          onForgot: () => forgotCallbacks++,
          onRequireOnboarding: () => onboardingCallbacks++,
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> dispose() async {
    appController.dispose();
    await deviceController.dispose();
    await states.close();
  }
}

final class _FakeBlePort implements DeviceBlePort {
  Completer<void>? forgetCompleter;
  int forgetFailures = 0;

  @override
  DeviceAdapterState get adapterState => DeviceAdapterState.on;
  @override
  Stream<DeviceAdapterState> get adapterStateStream => const Stream.empty();
  @override
  DeviceBlePhase get phase => DeviceBlePhase.disconnected;
  @override
  Stream<DeviceBlePhase> get phaseStream => const Stream.empty();
  @override
  Stream<DeviceInfo> get deviceInfoStream => const Stream.empty();
  @override
  Stream<DeviceTelemetry> get telemetryStream => const Stream.empty();
  @override
  Future<void> connectSaved(String remoteId) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> forgetBond() async {
    if (forgetFailures > 0) {
      forgetFailures--;
      throw StateError('missing ACK');
    }
    await forgetCompleter?.future;
  }
  @override
  Future<String> pair() async => 'echo';
  final mutes = <bool>[];

  @override
  Future<void> setMuted(bool muted) async => mutes.add(muted);

  final micGains = <int>[];

  @override
  Future<void> setMicGain(int gain) async => micGains.add(gain);

  final _power = StreamController<DevicePowerState>.broadcast(sync: true);
  int powerOffs = 0;
  int cancelPowerOffs = 0;

  @override
  Stream<DevicePowerState> get powerStateStream => _power.stream;

  @override
  Future<void> powerOff() async {
    powerOffs++;
    _power.add(DevicePowerState.turningOff);
  }

  @override
  Future<void> cancelPowerOff() async => cancelPowerOffs++;
}

final class _FakeIdentityStore implements DeviceIdentityStorePort {
  _FakeIdentityStore(this.value);
  String? value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<String?> loadRemoteId() async => value;
  @override
  Future<void> saveRemoteId(String remoteId) async => value = remoteId;
}

final class _FakeScheduler {
  int schedules = 0;
  DeviceRetryHandle schedule(Duration delay, void Function() callback) {
    schedules++;
    return _FakeRetryHandle();
  }
}

final class _FakeRetryHandle implements DeviceRetryHandle {
  @override
  void cancel() {}
}