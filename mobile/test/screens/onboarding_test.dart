import 'package:echo_app/screens/onboarding/onboarding_screen.dart';
import 'package:echo_app/services/app_preferences.dart';
import 'package:echo_app/services/build_defaults.dart';
import 'package:echo_app/services/onboarding_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OnboardingController', () {
    test('fresh install starts at backend without requesting permissions',
        () async {
      final fixture = _Fixture();

      await fixture.controller.initialize();

      expect(fixture.controller.value.step, OnboardingStep.backend);
      expect(fixture.permissions.totalCalls, 0);
    });

    test('invalid backend stays put and a valid retry advances', () async {
      final fixture = _Fixture();
      await fixture.controller.initialize();
      fixture.api.valid = false;

      await fixture.controller.submitBackend('https://echo.test', 'bad-key');

      expect(fixture.controller.value.step, OnboardingStep.backend);
      expect(fixture.controller.value.error, isNotNull);
      fixture.api.valid = true;
      await fixture.controller.submitBackend('https://echo.test', 'good-key');
      expect(fixture.controller.value.step, OnboardingStep.permissions);
      expect(fixture.api.configureCalls, 1);
      expect(
        fixture.preferences.getInt(OnboardingController.highestStepKey),
        OnboardingStep.backend.index,
      );
    });

    test('Bluetooth denial blocks remaining permission requests', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.backend.index,
      );
      fixture.permissions.bluetoothGranted = false;
      await fixture.controller.initialize();

      await fixture.controller.requestPermissions();

      expect(fixture.controller.value.step, OnboardingStep.permissions);
      expect(fixture.controller.value.error, contains('Bluetooth'));
      expect(fixture.permissions.bluetoothCalls, 1);
      expect(fixture.permissions.notificationCalls, 0);
      expect(fixture.permissions.voiceCalls, 0);
      expect(fixture.permissions.calls, ['bluetooth']);
    });

    test('notification denial proceeds in degraded mode', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.backend.index,
      );
      fixture.permissions.notificationGranted = false;
      await fixture.controller.initialize();

      await fixture.controller.requestPermissions();

      expect(fixture.controller.value.step, OnboardingStep.pairing);
      expect(fixture.controller.value.notificationDenied, isTrue);
      expect(fixture.controller.value.voiceDenied, isFalse);
      expect(
        fixture.permissions.calls,
        ['bluetooth', 'notifications', 'voice'],
      );
    });

    test('voice denial proceeds with voice Ask unavailable', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.backend.index,
      );
      fixture.permissions.voiceGranted = false;
      await fixture.controller.initialize();

      await fixture.controller.requestPermissions();

      expect(fixture.controller.value.step, OnboardingStep.pairing);
      expect(fixture.controller.value.voiceDenied, isTrue);
    });

    test('back navigation does not lower persisted progress', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.backend.index,
      );
      await fixture.controller.initialize();
      await fixture.controller.requestPermissions();

      fixture.controller.goBack();

      expect(fixture.controller.value.step, OnboardingStep.permissions);
      expect(
        fixture.preferences.getInt(OnboardingController.highestStepKey),
        OnboardingStep.permissions.index,
      );
    });

    test('persisted progress resumes every incomplete step', () async {
      final backend = _Fixture();
      await backend.controller.initialize();
      expect(backend.controller.value.step, OnboardingStep.backend);

      final permissions = _Fixture(
        configured: true,
        highestStep: OnboardingStep.backend.index,
      );
      await permissions.controller.initialize();
      expect(permissions.controller.value.step, OnboardingStep.permissions);

      final pairing = _Fixture(
        configured: true,
        highestStep: OnboardingStep.permissions.index,
      );
      await pairing.controller.initialize();
      expect(pairing.controller.value.step, OnboardingStep.pairing);

      final privacy = _Fixture(
        configured: true,
        hasIdentity: true,
        highestStep: OnboardingStep.pairing.index,
      );
      await privacy.controller.initialize();
      expect(privacy.controller.value.step, OnboardingStep.privacy);
    });

    test('pair failure stays for retry and success advances', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.permissions.index,
      );
      fixture.pairing.error = StateError('No Echo found');
      await fixture.controller.initialize();

      await fixture.controller.pair();

      expect(fixture.controller.value.step, OnboardingStep.pairing);
      expect(fixture.controller.value.error, contains('No Echo'));
      fixture.pairing
        ..error = null
        ..identityAfterPair = true;
      await fixture.controller.pair();
      expect(fixture.controller.value.step, OnboardingStep.privacy);
      expect(fixture.controller.value.paired, isTrue);
    });

    test('pair without a saved identity stays for retry', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.permissions.index,
      );
      await fixture.controller.initialize();

      await fixture.controller.pair();

      expect(fixture.controller.value.step, OnboardingStep.pairing);
      expect(fixture.controller.value.error, contains('No Echo'));
    });

    test('finish persists completion', () async {
      final fixture = _Fixture(
        configured: true,
        hasIdentity: true,
        highestStep: OnboardingStep.pairing.index,
      );
      await fixture.controller.initialize();

      await fixture.controller.complete();

      expect(fixture.controller.value.completed, isTrue);
      expect(
        fixture.preferences.getBool(OnboardingController.completedKey),
        isTrue,
      );
      expect(
        fixture.preferences.getInt(OnboardingController.highestStepKey),
        OnboardingStep.privacy.index,
      );
    });

    test('missing credentials override later persisted progress', () async {
      final fixture = _Fixture(
        configured: false,
        hasIdentity: true,
        highestStep: OnboardingStep.privacy.index,
        completed: true,
      );

      await fixture.controller.initialize();

      expect(fixture.controller.value.step, OnboardingStep.backend);
      expect(fixture.controller.value.completed, isFalse);
    });

    test('missing identity overrides later persisted progress', () async {
      final fixture = _Fixture(
        configured: true,
        hasIdentity: false,
        highestStep: OnboardingStep.privacy.index,
        completed: true,
      );

      await fixture.controller.initialize();

      expect(fixture.controller.value.step, OnboardingStep.pairing);
      expect(fixture.controller.value.completed, isFalse);
    });

    test('completed onboarding resumes as complete', () async {
      final fixture = _Fixture(
        configured: true,
        hasIdentity: true,
        highestStep: OnboardingStep.privacy.index,
        completed: true,
      );

      await fixture.controller.initialize();

      expect(fixture.controller.value.step, OnboardingStep.privacy);
      expect(fixture.controller.value.completed, isTrue);
    });
  });

  testWidgets('does not request permissions during initialization or build',
      (tester) async {
    final fixture = _Fixture(
      configured: true,
      highestStep: OnboardingStep.backend.index,
    );

    await _pumpOnboarding(tester, fixture.controller);

    expect(find.text('Permissions'), findsOneWidget);
    expect(fixture.permissions.totalCalls, 0);
  });

  testWidgets('final CTA persists and invokes completion callback',
      (tester) async {
    final fixture = _Fixture(
      configured: true,
      hasIdentity: true,
      highestStep: OnboardingStep.pairing.index,
    );
    var completed = false;

    await _pumpOnboarding(
      tester,
      fixture.controller,
      onComplete: () => completed = true,
    );
    await tester.tap(find.text('Start using Echo'));
    await tester.pump();

    expect(completed, isTrue);
    expect(fixture.controller.value.completed, isTrue);
  });

  testWidgets('prefills the backend URL from the build defaults',
      (tester) async {
    final fixture = _Fixture();

    await _pumpOnboarding(tester, fixture.controller);

    expect(
      find.widgetWithText(TextField, BuildDefaults.serverUrl),
      findsOneWidget,
    );
    expect(BuildDefaults.serverUrl, 'https://echo.man.ovh');
  });

  testWidgets('fits a 320 wide screen at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _Fixture();

    await _pumpOnboarding(
      tester,
      fixture.controller,
      textScaler: const TextScaler.linear(1.3),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Connect backend'), findsOneWidget);
  });
}

Future<void> _pumpOnboarding(
  WidgetTester tester,
  OnboardingController controller, {
  VoidCallback? onComplete,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: OnboardingScreen(
          controller: controller,
          onComplete: onComplete ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _Fixture {
  _Fixture({
    bool configured = false,
    bool hasIdentity = false,
    int? highestStep,
    bool completed = false,
  })  : api = _FakeApi(configured: configured),
        permissions = _FakePermissions(),
        pairing = _FakePairing(hasIdentity: hasIdentity),
        preferences = _FakePreferences({
          if (highestStep != null)
            OnboardingController.highestStepKey: highestStep,
          OnboardingController.completedKey: completed,
        }) {
    controller = OnboardingController(
      api: api,
      permissions: permissions,
      pairing: pairing,
      preferences: preferences,
    );
  }

  final _FakeApi api;
  final _FakePermissions permissions;
  final _FakePairing pairing;
  final _FakePreferences preferences;
  late final OnboardingController controller;
}

final class _FakeApi implements OnboardingApi {
  _FakeApi({required this.configured});

  bool configured;
  bool valid = true;
  int configureCalls = 0;

  @override
  Future<bool> isConfigured() async => configured;

  @override
  Future<bool> validateCredentials(String serverUrl, String apiKey) async {
    return valid;
  }

  @override
  Future<void> configure(String serverUrl, String apiKey) async {
    configureCalls++;
    configured = true;
  }
}

final class _FakePermissions implements OnboardingPermissions {
  bool bluetoothGranted = true;
  bool notificationGranted = true;
  bool voiceGranted = true;
  int bluetoothCalls = 0;
  int notificationCalls = 0;
  int voiceCalls = 0;
  final List<String> calls = [];

  int get totalCalls => bluetoothCalls + notificationCalls + voiceCalls;

  @override
  String get backgroundCapabilityExplanation =>
      'Background access keeps the wearable connected.';

  @override
  Future<bool> requestBluetooth() async {
    bluetoothCalls++;
    calls.add('bluetooth');
    return bluetoothGranted;
  }

  @override
  Future<bool> requestNotifications() async {
    notificationCalls++;
    calls.add('notifications');
    return notificationGranted;
  }

  @override
  Future<bool> requestVoiceMicrophone() async {
    voiceCalls++;
    calls.add('voice');
    return voiceGranted;
  }
}

final class _FakePairing implements OnboardingPairing {
  _FakePairing({required bool hasIdentity}) : _hasIdentity = hasIdentity;

  bool _hasIdentity;
  bool identityAfterPair = false;
  Object? error;
  int pairCalls = 0;

  @override
  Future<bool> hasIdentity() async => _hasIdentity;

  @override
  Future<void> pair() async {
    pairCalls++;
    if (error case final error?) throw error;
    _hasIdentity = identityAfterPair;
  }
}

final class _FakePreferences implements AppPreferences {
  _FakePreferences([Map<String, Object>? initial]) {
    if (initial != null) values.addAll(initial);
  }

  final Map<String, Object> values = {};

  @override
  bool? getBool(String key) => values[key] as bool?;

  @override
  int? getInt(String key) => values[key] as int?;

  @override
  String? getString(String key) => values[key] as String?;

  @override
  Future<bool> setBool(String key, bool value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }
}