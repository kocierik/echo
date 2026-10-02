import 'dart:async';

import 'package:echo_app/models/app_view_state.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/session_state.dart';
import 'package:echo_app/services/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<DeviceStatus> devices;
  late StreamController<SessionState> sessions;
  late _FakeAppPreferences preferences;
  late AppController controller;

  const initialDevice = DeviceStatus(
    connectionState: DeviceConnectionState.unpaired,
  );
  const initialSession = SessionState(SessionStatus.loggedIn);

  Future<AppController> createController() async {
    final result = AppController(
      initialDevice: initialDevice,
      deviceStates: devices.stream,
      initialSession: initialSession,
      sessionStates: sessions.stream,
      preferences: preferences,
    );
    await result.initialize();
    return result;
  }

  setUp(() {
    devices = StreamController<DeviceStatus>.broadcast(sync: true);
    sessions = StreamController<SessionState>.broadcast(sync: true);
    preferences = _FakeAppPreferences();
  });

  tearDown(() async {
    controller.dispose();
    await devices.close();
    await sessions.close();
  });

  test('restores a valid theme and selected tab', () async {
    preferences.values[AppController.themePreferenceKey] = 'dark';
    preferences.values[AppController.selectedTabKey] = 2;

    controller = await createController();

    expect(controller.value.themePreference, ThemePreference.dark);
    expect(controller.themeMode, ThemeMode.dark);
    expect(controller.value.selectedTab, 2);
  });

  test('invalid restored values fall back to system and the first tab',
      () async {
    preferences.values[AppController.themePreferenceKey] = 'sepia';
    preferences.values[AppController.selectedTabKey] = 9;

    controller = await createController();

    expect(controller.value.themePreference, ThemePreference.system);
    expect(controller.themeMode, ThemeMode.system);
    expect(controller.value.selectedTab, 0);
  });

  test('device and session updates notify only when state changes', () async {
    controller = await createController();
    var notifications = 0;
    controller.addListener(() => notifications++);

    devices.add(initialDevice);
    sessions.add(initialSession);
    expect(notifications, 0);

    const connected = DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      batteryPercent: 84,
      protocolVersion: 2,
      firmwareVersion: '1.4.7',
    );
    const loggedOut = SessionState(SessionStatus.loggedOut);
    devices.add(connected);
    sessions.add(loggedOut);

    expect(controller.value.device, connected);
    expect(controller.value.device.protocolVersion, 2);
    expect(controller.value.device.firmwareVersion, '1.4.7');
    expect(controller.value.session, loggedOut);
    expect(notifications, 2);
  });

  test('theme and tab changes persist and validate their inputs', () async {
    controller = await createController();

    await controller.setTheme(ThemePreference.light);
    await controller.setSelectedTab(1);

    expect(controller.themeMode, ThemeMode.light);
    expect(controller.value.selectedTab, 1);
    expect(
      preferences.values[AppController.themePreferenceKey],
      'light',
    );
    expect(preferences.values[AppController.selectedTabKey], 1);
    expect(() => controller.setSelectedTab(3), throwsRangeError);
  });

  test('initialize is idempotent and subscribes to each stream once',
      () async {
    controller = await createController();
    await controller.initialize();
    var notifications = 0;
    controller.addListener(() => notifications++);

    devices.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
    ));
    sessions.add(const SessionState(SessionStatus.loggedOut));

    expect(notifications, 2);
  });

  test('dispose ignores later stream events', () async {
    controller = await createController();
    final stateBeforeDispose = controller.value;
    controller.dispose();

    devices.add(const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
    ));
    sessions.add(const SessionState(SessionStatus.loggedOut));

    expect(controller.value, stateBeforeDispose);
    controller = AppController(
      initialDevice: initialDevice,
      deviceStates: const Stream<DeviceStatus>.empty(),
      initialSession: initialSession,
      sessionStates: const Stream<SessionState>.empty(),
      preferences: preferences,
    );
  });
}

final class _FakeAppPreferences implements AppPreferences {
  final Map<String, Object> values = {};

  @override
  bool? getBool(String key) => values[key] as bool?;

  @override
  int? getInt(String key) => values[key] as int?;

  @override
  String? getString(String key) => values[key] as String?;

  @override
  Future<bool> setInt(String key, int value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }
}