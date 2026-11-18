import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/assistant.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/place.dart';
import 'package:echo_app/models/plan.dart';
import 'package:echo_app/models/voice.dart';
import 'package:echo_app/models/whatsapp.dart';
import 'package:echo_app/screens/account_sheet.dart';
import 'package:echo_app/screens/echo_device_screen.dart';
import 'package:echo_app/screens/settings/whatsapp_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/app/app_controller.dart';
import 'package:echo_app/services/device/device_ble_port.dart';
import 'package:echo_app/services/device/device_controller.dart';
import 'package:echo_app/services/device/device_identity_store.dart';
import 'package:echo_app/services/device/device_protocol.dart';
import 'package:echo_app/services/app/network_policy.dart';
import 'package:echo_app/services/app/session_controller.dart';
import 'package:echo_app/services/app/spoken_answers_store.dart';
import 'package:echo_app/services/app/spoken_language.dart';
import 'package:echo_app/services/phone/places_visited.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/account_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/plan_test.dart' show planJson;
import '../services/phone/places_visited_test.dart' show FakeNetwork, FakeSource;

void main() {
  late SharedPreferences preferences;
  late AppController appController;
  late DeviceController deviceController;
  late _FakeBlePort ble;
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
        batteryPercent: 72,
        firmwareVersion: '0.5.1',
        bufferCount: 3,
      ),
      deviceStates: const Stream.empty(),
      initialSession: const SessionState(SessionStatus.loggedIn),
      sessionStates: const Stream.empty(),
      preferences: SharedPreferencesAppPreferences(preferences),
    );
    await appController.initialize();
    ble = _FakeBlePort();
    deviceController = DeviceController(ble: ble, identityStore: _FakeIdentityStore());
    session = _SessionFixture();
    networkPolicy = NetworkPolicy();
    api = _FakeApiService();
  });

  tearDown(() async {
    appController.dispose();
    await deviceController.dispose();
    await session.controller.dispose();
  });

  /// A tall screen: the sheet lists every row at once.
  void widgetTest(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await body(tester);
    });
  }

  PlacesVisitedService defaultPlaces() => PlacesVisitedService(
        source: FakeSource(),
        api: api,
        preferences: preferences,
        networkAccess: FakeNetwork({NetworkType.wifi}),
        networkPolicy: networkPolicy,
      );

  Widget host({
    VoidCallback? onRequireOnboarding,
    PlacesVisitedService? placesVisited,
    SpokenAnswersStore? spokenAnswers,
    String? name,
    double textScale = 1,
  }) {
    return MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: AccountButton(
              initial: name?.characters.first,
              onTap: () => showAccountSheet(
                context,
                appController: appController,
                deviceController: deviceController,
                sessionController: session.controller,
                networkPolicy: networkPolicy,
                preferences: preferences,
                onRequireOnboarding: onRequireOnboarding,
                apiServiceFactory: () => api,
                diagnosticsBuilder: (_) => const Scaffold(body: Text('Diagnostics route')),
                activityBuilder: (_) => const Scaffold(body: Text('Activity route')),
                integrationsBuilder: (_) => const Scaffold(body: Text('Integrations route')),
                devicesBuilder: (_) => const Scaffold(body: Text('Devices route')),
                placesVisited: placesVisited ?? defaultPlaces(),
                spokenAnswers: spokenAnswers ?? SpokenAnswersStore(preferences),
                onTrySpeaking: () async {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpAccountSheet(
    WidgetTester tester, {
    VoidCallback? onRequireOnboarding,
    PlacesVisitedService? placesVisited,
    SpokenAnswersStore? spokenAnswers,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(const SizedBox()); // a fresh app each time
    await tester.pumpWidget(host(
      onRequireOnboarding: onRequireOnboarding,
      placesVisited: placesVisited,
      spokenAnswers: spokenAnswers,
      textScale: textScale,
    ));
    await tester.tap(find.bySemanticsLabel('Account'));
    await tester.pumpAndSettle();
  }

  Future<void> pumpWithAccountButton(WidgetTester tester, {String? name}) async {
    await tester.pumpWidget(host(name: name));
  }

  Future<void> tapRow(WidgetTester tester, Finder row) async {
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// The sheet, with the row for [label] tapped (the sheet closes, the page opens).
  Future<void> openRow(WidgetTester tester, String label) async {
    await pumpAccountSheet(tester);
    await tapRow(tester, find.text(label));
  }

  Future<void> openAbout(WidgetTester tester, {VoidCallback? onRequireOnboarding}) async {
    await pumpAccountSheet(tester, onRequireOnboarding: onRequireOnboarding);
    await tapRow(tester, find.text('About'));
  }

  testWidgets('the sheet lists the pendant, then Echo does, You and Settings', (tester) async {
    tester.view.physicalSize = const Size(1200, 8000); // every row built at once
    addTearDown(tester.view.reset);
    await pumpAccountSheet(tester);
    const order = ['ECHO DOES', 'Routines', 'Apps', 'WhatsApp', 'Notifications', 'Spoken answers',
        'Activity', 'YOU', 'About you', 'Voices', 'Assistants', 'Language', 'SETTINGS',
        'Appearance', 'Privacy', 'Places visited', 'Health', 'Plan', 'Devices',
        'Server connection', 'Diagnostics', 'What Echo can do', 'Example data', 'About'];
    final shown = tester
        .widgetList<Text>(find.descendant(of: find.byType(AccountSheet), matching: find.byType(Text)))
        .map((t) => t.data)
        .where(order.contains)
        .toList();
    expect(shown, order);
    expect(find.byKey(const Key('account-pendant')), findsOneWidget); // the pendant card, first
  });

  widgetTest('About you opens the memory page, which offers Instructions', (tester) async {
    await pumpAccountSheet(tester);
    await tester.tap(find.text('About you'));
    await tester.pumpAndSettle();
    expect(find.text('Instructions'), findsOneWidget);
  });

  widgetTest('the circle shows the initial and opens the sheet', (tester) async {
    await pumpWithAccountButton(tester, name: 'Erik');
    expect(find.text('E'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Account'));
    await tester.pumpAndSettle();
    expect(find.text('ECHO DOES'), findsOneWidget);
  });

  widgetTest('the pendant card says the state, battery, segments and firmware', (tester) async {
    await pumpAccountSheet(tester);
    final card = find.byKey(const Key('account-pendant'));
    for (final part in ['Listening', '72%', '3 waiting', '0.5.1']) {
      expect(find.descendant(of: card, matching: find.textContaining(part)), findsWidgets,
          reason: part);
    }
  });

  widgetTest('the Mute switch mutes the pendant', (tester) async {
    await pumpAccountSheet(tester);
    await tester.tap(find.byKey(const Key('account-mute')));
    await tester.pumpAndSettle();
    expect(ble.mutes, [true]);
  });

  widgetTest('a tap on the pendant card opens the Echo screen', (tester) async {
    await pumpAccountSheet(tester);
    await tester.tap(find.byKey(const Key('account-pendant-open')));
    await tester.pumpAndSettle();
    expect(find.byType(EchoDeviceScreen), findsOneWidget);
    expect(find.text('ECHO DOES'), findsNothing); // the sheet closed
  });

  widgetTest('the Plan row names the plan and opens it', (tester) async {
    await pumpAccountSheet(tester);
    expect(find.text('Plus'), findsOneWidget);
    await tapRow(tester, find.byKey(const Key('account-plan')));
    expect(find.text('Starts again on 1 November.'), findsOneWidget);
  });

  widgetTest('no Plan row when the server cannot say', (tester) async {
    api.plan = null;
    await pumpAccountSheet(tester);
    expect(find.byKey(const Key('account-plan')), findsNothing);
    expect(find.text('ECHO DOES'), findsOneWidget);
  });

  widgetTest('Places visited: off by default, in Settings', (tester) async {
    final places = defaultPlaces();
    await pumpAccountSheet(tester, placesVisited: places);

    expect(find.text('Off. Echo can note where you stay.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Places visited')).dy,
      greaterThan(tester.getTopLeft(find.text('Privacy')).dy),
    );
    await tapRow(tester, find.byKey(const Key('account-places')));
    expect(find.byKey(const Key('places-switch')), findsOneWidget);
  });

  widgetTest('Spoken answers says the choice and opens its page', (tester) async {
    final store = SpokenAnswersStore(preferences);
    await store.set(SpokenAnswers.headphones);
    await pumpAccountSheet(tester, spokenAnswers: store);

    final row = find.byKey(const Key('account-spoken-answers'));
    expect(find.descendant(of: row, matching: find.text('Spoken answers')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('headphones')), findsOneWidget);
    await tapRow(tester, row);
    expect(find.byKey(const Key('spoken-answers-control')), findsOneWidget);
  });

  widgetTest('Example data opens its switch', (tester) async {
    api.exampleData = true;
    await pumpAccountSheet(tester);
    await tapRow(tester, find.byKey(const Key('account-example-data')));
    expect(tester.widget<Switch>(find.byKey(const Key('example-data-switch'))).value, isTrue);
  });

  widgetTest('About you opens About you and Documents', (tester) async {
    await openRow(tester, 'About you');
    expect(find.byKey(const Key('memory-about-you')), findsOneWidget);
    expect(find.byKey(const Key('memory-documents')), findsOneWidget);
  });

  widgetTest('Instructions, in the memory page, opens the editor', (tester) async {
    await openRow(tester, 'About you');
    await tester.tap(find.byKey(const Key('memory-instructions')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  widgetTest('Instructions: a save is what the editor shows next time', (tester) async {
    await openRow(tester, 'About you');
    await tester.tap(find.byKey(const Key('memory-instructions')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep it short');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Keep it short'), findsOneWidget); // the row's subtitle
    await tester.tap(find.byKey(const Key('memory-instructions')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Keep it short'), findsOneWidget);
  });

  widgetTest('Instructions does not open an empty editor while the account is unknown',
      (tester) async {
    api.meGate = Completer<void>();
    await openRow(tester, 'About you');
    await tester.tap(find.byKey(const Key('memory-instructions')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    api.meGate!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-instructions')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Be brief'), findsOneWidget);
  });

  widgetTest('the Mute switch has a spoken label', (tester) async {
    await pumpAccountSheet(tester);
    expect(find.bySemanticsLabel('Mute'), findsOneWidget);
  });

  widgetTest('the About row says who is signed in', (tester) async {
    await pumpAccountSheet(tester);
    expect(find.text('Signed in as erik@x.io'), findsOneWidget);
  });

  widgetTest('a mute that fails says so', (tester) async {
    ble.failMute = true;
    await pumpAccountSheet(tester);
    await tester.tap(find.byKey(const Key('account-mute')));
    await tester.pumpAndSettle();
    expect(find.text('Echo could not update the microphone.'), findsOneWidget);
  });

  widgetTest('Assistants opens the list', (tester) async {
    await openRow(tester, 'Assistants');
    expect(find.byKey(const Key('assistants-new')), findsOneWidget);
  });

  widgetTest('WhatsApp is a row of Echo does, and shows among the connected apps', (tester) async {
    api.whatsapp =
        const WhatsAppStatus(available: true, state: 'linked', phone: '+393330000000');
    await pumpAccountSheet(tester);
    expect(find.text('WhatsApp, Gmail, Google Calendar'), findsOneWidget);
    await tapRow(tester, find.byKey(const Key('account-whatsapp')));
    expect(find.byType(WhatsAppScreen), findsOneWidget);
  });

  widgetTest('the rows open their screens', (tester) async {
    for (final (label, shown) in [
      ('Activity', 'Activity route'),
      ('Apps', 'Integrations route'),
      ('Diagnostics', 'Diagnostics route'),
      ('Devices', 'Devices route'),
      ('Privacy', '24 hours'),
    ]) {
      await openRow(tester, label);
      expect(find.text(shown), findsOneWidget, reason: label);
      expect(find.text('ECHO DOES'), findsNothing, reason: label); // the sheet closed
    }
  });

  widgetTest('fits 320 wide at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    await pumpAccountSheet(tester, textScale: 1.3);
    expect(tester.takeException(), isNull);
  });

  widgetTest('appearance persists system light and dark selections', (tester) async {
    await pumpAccountSheet(tester);
    expect(find.text('System: light by day, dark at night'), findsOneWidget);
    await tapRow(tester, find.text('Appearance'));

    for (final entry in const {'Light': 'light', 'Dark': 'dark', 'System': 'system'}.entries) {
      await tester.tap(find.text(entry.key));
      await tester.pump();
      expect(preferences.getString(AppController.themePreferenceKey), entry.value);
    }
  });

  widgetTest('cellular toggle mutates the shared policy and persists', (tester) async {
    await openRow(tester, 'Server connection');
    await tester.tap(find.byKey(const Key('allow-cellular-switch')));
    await tester.pump();

    expect(networkPolicy.allowCellular, isFalse);
    expect(preferences.getBool('echo_allow_cellular'), isFalse);
  });

  widgetTest('backend rejects an invalid URL before calling the API', (tester) async {
    await openRow(tester, 'Server connection');
    await tester.enterText(find.byKey(const Key('server-url-field')), 'not a URL');
    await tester.enterText(find.byKey(const Key('api-key-field')), 'secret');
    await tester.tap(find.byKey(const Key('save-connection')));
    await tester.pump();

    expect(find.text('Enter a valid HTTP or HTTPS server URL.'), findsOneWidget);
    expect(api.validationCalls, 0);
  });

  widgetTest('logout cancel leaves session active and success resets root', (tester) async {
    var resets = 0;
    await openAbout(tester, onRequireOnboarding: () => resets++);

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

  widgetTest('logout failure remains visible and can be retried', (tester) async {
    session.failCacheOnce = true;
    await openAbout(tester);
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
      const AccountInfo(email: 'erik@x.io', language: 'it', instructions: 'Be brief');

  /// Holds me() back, to see the pages before the account is known.
  Completer<void>? meGate;

  @override
  Future<AccountInfo> me() async {
    await meGate?.future;
    return account;
  }

  @override
  Future<AccountInfo> setInstructions(String? instructions) async =>
      account = AccountInfo(email: account.email, language: account.language, instructions: instructions);

  /// None: the server cannot say (an older one).
  PlanInfo? plan = PlanInfo.fromJson(planJson());

  WhatsAppStatus whatsapp = const WhatsAppStatus(available: true, state: 'unlinked');

  @override
  Future<WhatsAppStatus> getWhatsApp() async => whatsapp;

  @override
  Future<List<Assistant>> listAssistants() async => const [];

  bool exampleData = false;

  @override
  Future<bool> exampleDataOn() async => exampleData;

  @override
  Future<PlanInfo> getPlan() async => plan ?? (throw Exception('no plan'));

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

  bool failMute = false;

  @override
  Future<void> setMuted(bool muted) async {
    if (failMute) throw StateError('ble');
    mutes.add(muted);
  }

  final micGains = <int>[];

  @override
  Future<void> setMicGain(int gain) async => micGains.add(gain);

  @override
  Stream<DevicePowerState> get powerStateStream => const Stream.empty();

  @override
  Future<void> powerOff() async {}

  @override
  Future<void> cancelPowerOff() async {}
}