import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/place.dart';
import 'package:echo_app/models/plan.dart';
import 'package:echo_app/models/voice.dart';
import 'package:echo_app/screens/profile_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/app/app_controller.dart';
import 'package:echo_app/services/device/device_ble_port.dart';
import 'package:echo_app/services/device/device_controller.dart';
import 'package:echo_app/services/device/device_identity_store.dart';
import 'package:echo_app/services/device/device_protocol.dart';
import 'package:echo_app/services/app/network_policy.dart';
import 'package:echo_app/services/app/session_controller.dart';
import 'package:echo_app/services/app/spoken_language.dart';
import 'package:echo_app/services/phone/places_visited.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/plan_test.dart' show planJson;
import '../services/phone/places_visited_test.dart' show FakeNetwork, FakeSource;

void main() {
  late SharedPreferences preferences;
  late AppController appController;
  late DeviceController deviceController;
  late _SessionFixture session;
  late NetworkPolicy networkPolicy;
  late _FakeApiService api;
  var openedDevice = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      SharedPreferencesApiCredentialStore.serverKey: 'https://echo.test',
    });
    preferences = await SharedPreferences.getInstance();
    appController = AppController(
      initialDevice: const DeviceStatus(
        connectionState: DeviceConnectionState.listening,
        batteryPercent: 72,
        firmwareVersion: '0.5.1',
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
    openedDevice = 0;
  });

  tearDown(() async {
    appController.dispose();
    await deviceController.dispose();
    await session.controller.dispose();
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    VoidCallback? onRequireOnboarding,
    PlacesVisitedService? placesVisited,
  }) async {
    // Tall enough for every row: the list builds only what is on screen
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: ProfileScreen(
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
        devicesBuilder: (_) => const Scaffold(body: Text('Devices route')),
        onOpenDevice: () => openedDevice++,
        placesVisited: placesVisited,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openMore(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Devices, server, diagnostics, about'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devices, server, diagnostics, about'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the account, Echo, then the groups in order, without placeholders',
      (tester) async {
    await pumpSettings(tester);

    const labels = [
      'Profile',
      'Erik',
      'erik@x.io · Italiano',
      'Echo',
      'Listening · battery 72% · firmware 0.5.1',
      'Plan',
      '12 h of 25 h this month',
      'ECHO DOES',
      'Apps',
      'Routines',
      'Notifications',
      'Activity',
      'YOU',
      'Instructions',
      'Voices',
      'Language',
      'Privacy',
      'Appearance',
      'What Echo can do',
      'Devices, server, diagnostics, about',
    ];
    final tops = <double>[];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget, reason: label);
      tops.add(tester.getTopLeft(find.text(label)).dy);
    }
    expect(tops, orderedEquals([...tops]..sort()));
    // The connected apps by name
    expect(find.text('Gmail, Google Calendar'), findsOneWidget);
    expect(find.textContaining('Coming soon'), findsNothing);
    expect(find.textContaining('Placeholder'), findsNothing);
  });

  testWidgets('the Plan row names the plan and opens it', (tester) async {
    await pumpSettings(tester);

    expect(find.text('Plus'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-plan')));
    await tester.pumpAndSettle();

    expect(find.text('Starts again on 1 November.'), findsOneWidget);
  });

  testWidgets('no Plan row when the server cannot say', (tester) async {
    api.plan = null;
    await pumpSettings(tester);

    expect(find.byKey(const Key('profile-plan')), findsNothing);
    expect(find.text('ECHO DOES'), findsOneWidget);
  });

  testWidgets('Places visited: off by default, one tap from You', (tester) async {
    final places = PlacesVisitedService(
      source: FakeSource(),
      api: api,
      preferences: preferences,
      networkAccess: FakeNetwork({NetworkType.wifi}),
      networkPolicy: networkPolicy,
    );
    await pumpSettings(tester, placesVisited: places);

    expect(find.text('Off. Echo can note where you stay.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Places visited')).dy,
      greaterThan(tester.getTopLeft(find.text('Privacy')).dy),
    );
    await tester.tap(find.byKey(const Key('profile-places')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('places-switch')), findsOneWidget);
  });

  testWidgets('the name is set from Profile, prefilled from the own voice',
      (tester) async {
    api.account = const AccountInfo(email: 'erik@x.io', language: 'it');
    await pumpSettings(tester);
    expect(find.text('Add your name'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-account')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('profile-name-field')));
    expect(field.controller!.text, 'Erik R.');

    await tester.enterText(find.byKey(const Key('profile-name-field')), 'Erik');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.names, ['Erik']);
    expect(find.text('Erik'), findsOneWidget);
  });

  testWidgets('the Echo card opens the Echo screen; the rest sits one row down',
      (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('profile-device')));
    await tester.pumpAndSettle();
    expect(openedDevice, 1);

    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.text('24 hours'), findsOneWidget);
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('Until transcribed'), findsOneWidget); // speech past the budget
    Navigator.of(tester.element(find.text('Privacy'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Activity route'), findsOneWidget);
    Navigator.of(tester.element(find.text('Activity route'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    expect(find.text('Integrations route'), findsOneWidget);
    Navigator.of(tester.element(find.text('Integrations route'))).pop();
    await tester.pumpAndSettle();

    await openMore(tester);
    for (final label in ['Devices', 'Server connection', 'Diagnostics', 'About']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics route'), findsOneWidget);
    Navigator.of(tester.element(find.text('Diagnostics route'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
    expect(find.text('Devices route'), findsOneWidget);
  });

  testWidgets('fits 320 wide at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: ProfileScreen(
          deviceController: deviceController,
          appController: appController,
          sessionController: session.controller,
          networkPolicy: networkPolicy,
          preferences: preferences,
          apiServiceFactory: () => api,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance persists system light and dark selections',
      (tester) async {
    await pumpSettings(tester);
    expect(find.text('System: light by day, dark at night'), findsOneWidget);
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
    await openMore(tester);
    await tester.tap(find.text('Server connection'));
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
    await openMore(tester);
    await tester.tap(find.text('Server connection'));
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
    await openMore(tester);
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
    await openMore(tester);
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

  @override
  Future<VisitPage> listVisits({DateTime? before}) async =>
      const VisitPage(visits: [], more: false);

  int validationCalls = 0;
  AccountInfo account =
      const AccountInfo(email: 'erik@x.io', language: 'it', name: 'Erik');
  final names = <String?>[];

  @override
  Future<AccountInfo> me() async => account;

  /// None: the server cannot say (an older one).
  PlanInfo? plan = PlanInfo.fromJson(planJson());

  @override
  Future<PlanInfo> getPlan() async => plan ?? (throw Exception('no plan'));

  @override
  Future<AccountInfo> setName(String? name) async {
    names.add(name);
    return account = AccountInfo(email: account.email, language: account.language, name: name);
  }

  @override
  Future<VoiceProfiles> getVoiceProfiles() async => const VoiceProfiles(
        fingerprintsEnabled: true,
        items: [VoiceProfile(id: 'v1', name: 'Erik R.', isSelf: true)],
      );

  @override
  Future<List<Toolkit>> getToolkits({String? query}) async => const [
        Toolkit(slug: 'gmail', name: 'Gmail', description: '', connected: true),
        Toolkit(slug: 'googlecalendar', name: 'Google Calendar', description: '', connected: true),
        Toolkit(slug: 'slack', name: 'Slack', description: '', connected: false),
      ];

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
  final mutes = <bool>[];

  @override
  Future<void> setMuted(bool muted) async => mutes.add(muted);
}