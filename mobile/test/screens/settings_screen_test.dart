import 'dart:async';

import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/screens/settings_screen.dart';
import 'package:echo_app/services/api_service.dart';
import 'package:echo_app/services/app_controller.dart';
import 'package:echo_app/services/device_ble_port.dart';
import 'package:echo_app/services/device_controller.dart';
import 'package:echo_app/services/device_identity_store.dart';
import 'package:echo_app/services/device_protocol.dart';
import 'package:echo_app/services/network_policy.dart';
import 'package:echo_app/services/session_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences preferences;
  late AppController appController;
  late DeviceController deviceController;
  late _SessionFixture session;
  late NetworkPolicy networkPolicy;
  late _FakeApiService api;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      SharedPreferencesApiCredentialStore.serverKey: 'https://echo.test',
    });
    preferences = await SharedPreferences.getInstance();
    appController = AppController(
      initialDevice: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
      ),
      deviceStates: const Stream.empty(),
      initialSession: const SessionState(SessionStatus.loggedIn),
      sessionStates: const Stream.empty(),
      preferences: SharedPreferencesAppPreferences(preferences),
    );
    await appController.initialize();
    deviceController = DeviceController(
      ble: _FakeBlePort(),
      identityStore: _FakeIdentityStore(),
    );
    session = _SessionFixture();
    networkPolicy = NetworkPolicy();
    api = _FakeApiService();
  });

  tearDown(() async {
    appController.dispose();
    await deviceController.dispose();
    await session.controller.dispose();
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    VoidCallback? onRequireOnboarding,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: SettingsScreen(
        deviceController: deviceController,
        appController: appController,
        sessionController: session.controller,
        networkPolicy: networkPolicy,
        preferences: preferences,
        onRequireOnboarding: onRequireOnboarding,
        apiServiceFactory: () => api,
        diagnosticsBuilder: (_) => const Scaffold(
          body: Text('Diagnostics route'),
        ),
        activityBuilder: (_) => const Scaffold(body: Text('Activity route')),
        integrationsBuilder: (_) =>
            const Scaffold(body: Text('Integrations route')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('shows exact hierarchical headers and row order without placeholders',
      (tester) async {
    await pumpSettings(tester);

    const labels = [
      'DEVICE',
      'Device',
      'Connection',
      'Privacy',
      'ECHO',
      'Automations',
      'Diagnostics',
      'About',
    ];
    final tops = <double>[];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget);
      tops.add(tester.getTopLeft(find.text(label)).dy);
    }
    expect(tops, orderedEquals([...tops]..sort()));
    expect(find.textContaining('Coming soon'), findsNothing);
    expect(find.textContaining('Placeholder'), findsNothing);
  });

  testWidgets('opens device, privacy, diagnostics, and automation routes',
      (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text('Device'));
    await tester.pumpAndSettle();
    expect(find.text('Buffered segments'), findsOneWidget);
    Navigator.of(tester.element(find.text('Buffered segments'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.text('24 hours'), findsOneWidget);
    expect(find.text('7 days'), findsOneWidget);
    Navigator.of(tester.element(find.text('Privacy'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics route'), findsOneWidget);
    Navigator.of(tester.element(find.text('Diagnostics route'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Automations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Activity route'), findsOneWidget);
  });

  testWidgets('automations exposes both real destinations', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Automations'));
    await tester.pumpAndSettle();

    expect(find.text('Rules'), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Integrations'), findsOneWidget);
    await tester.tap(find.text('Integrations'));
    await tester.pumpAndSettle();
    expect(find.text('Integrations route'), findsOneWidget);
  });

  testWidgets('appearance persists system light and dark selections',
      (tester) async {
    await pumpSettings(tester);
    await tester.ensureVisible(find.text('About'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    for (final entry in const {
      'Light': 'light',
      'Dark': 'dark',
      'System': 'system',
    }.entries) {
      await tester.tap(find.text(entry.key));
      await tester.pump();
      expect(
        preferences.getString(AppController.themePreferenceKey),
        entry.value,
      );
    }
  });

  testWidgets('cellular toggle mutates the shared policy and persists',
      (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Connection'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('allow-cellular-switch')));
    await tester.pump();

    expect(networkPolicy.allowCellular, isFalse);
    expect(
      preferences.getBool('echo_allow_cellular'),
      isFalse,
    );
  });

  testWidgets('backend rejects an invalid URL before calling the API',
      (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Connection'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'not a URL',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), 'secret');
    await tester.tap(find.byKey(const Key('save-connection')));
    await tester.pump();

    expect(find.text('Enter a valid HTTP or HTTPS server URL.'), findsOneWidget);
    expect(api.validationCalls, 0);
  });

  testWidgets('logout cancel leaves session active and success resets root',
      (tester) async {
    var resets = 0;
    await pumpSettings(tester, onRequireOnboarding: () => resets++);
    await tester.ensureVisible(find.text('About'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(session.calls, isEmpty);

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();

    expect(session.controller.state.loggedOut, isTrue);
    expect(resets, 1);
  });

  testWidgets('logout failure remains visible and can be retried',
      (tester) async {
    session.failCacheOnce = true;
    await pumpSettings(tester);
    await tester.ensureVisible(find.text('About'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('logout-cleanup-error')), findsOneWidget);
    expect(find.text('Retry logout'), findsOneWidget);

    await tester.tap(find.text('Retry logout'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();
    expect(session.controller.state.loggedOut, isTrue);
  });
}

final class _FakeApiService extends ApiService {
  _FakeApiService();

  int validationCalls = 0;

  @override
  Future<String> getServerUrl() async => 'https://echo.test';

  @override
  Future<bool> validateCredentials(String serverUrl, String apiKey) async {
    validationCalls++;
    return true;
  }

  @override
  Future<void> configure(String serverUrl, String apiKey) async {}

  @override
  Future<bool> testConnection() async => true;
}

final class _SessionFixture {
  _SessionFixture() {
    controller = SessionController(
      bleStopper: _Action(() async => calls.add('ble')),
      apiCredentials: _Clearer(() async => calls.add('api')),
      deviceIdentity: _Clearer(() async => calls.add('identity')),
      sessionCache: _Clearer(() async {
        calls.add('cache');
        if (failCacheOnce) {
          failCacheOnce = false;
          throw StateError('cache unavailable');
        }
      }),
    );
  }

  final calls = <String>[];
  bool failCacheOnce = false;
  late final SessionController controller;
}

final class _Action implements ActiveBleStopper {
  const _Action(this.action);
  final Future<void> Function() action;
  @override
  Future<void> stop() => action();
}

final class _Clearer
    implements ApiCredentialsClearer, DeviceIdentityClearer, SessionCacheClearer {
  const _Clearer(this.action);
  final Future<void> Function() action;
  @override
  Future<void> clear() => action();
}

final class _FakeIdentityStore implements DeviceIdentityStorePort {
  @override
  Future<void> clear() async {}
  @override
  Future<String?> loadRemoteId() async => null;
  @override
  Future<void> saveRemoteId(String remoteId) async {}
}

final class _FakeBlePort implements DeviceBlePort {
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
  Future<void> forgetBond() async {}
  @override
  Future<String> pair() async => 'echo';
  @override
  Future<void> setMuted(bool muted) async {}
}