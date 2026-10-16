import 'package:echo_app/screens/onboarding/onboarding_screen.dart';
import 'package:echo_app/services/app/app_preferences.dart';
import 'package:echo_app/services/api/auth_api.dart';
import 'package:echo_app/services/onboarding/onboarding_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OnboardingController', () {
    test('a fresh install starts on the welcome', () async {
      final fixture = _Fixture();

      await fixture.controller.initialize();

      expect(fixture.controller.value.step, OnboardingStep.signIn);
      expect(fixture.controller.value.showWelcome, isTrue);
      expect(fixture.permissions.totalCalls, 0);
    });

    test('the email form opens from the welcome and goes back to it', () async {
      final fixture = _Fixture();
      await fixture.controller.initialize();

      fixture.controller.continueWithEmail();
      expect(fixture.controller.value.showWelcome, isFalse);
      fixture.controller.backToWelcome();
      expect(fixture.controller.value.showWelcome, isTrue);
    });

    test('empty fields ask for both', () async {
      final fixture = _Fixture();
      await fixture.controller.initialize();

      await fixture.controller.signIn('  ', '');

      expect(fixture.controller.value.error, 'Enter your email and password.');
      expect(fixture.api.signInCalls, 0);
    });

    test('signIn reports no connection, not wrong password', () async {
      final fixture = _Fixture();
      await fixture.controller.initialize();
      fixture.api.signInError = const SignInException(
        SignInFailure.noConnection,
        'No connection. Check your internet and try again.',
      );

      await fixture.controller.signIn('erik@example.com', 'correct horse');

      expect(fixture.controller.value.step, OnboardingStep.signIn);
      expect(fixture.controller.value.busy, isFalse);
      expect(
        fixture.controller.value.error,
        'No connection. Check your internet and try again.',
      );
    });

    test('a valid sign-in advances to permissions and keeps the progress', () async {
      final fixture = _Fixture();
      await fixture.controller.initialize();
      fixture.controller.continueWithEmail();

      await fixture.controller.signIn(' erik@example.com ', 'correct horse');

      expect(fixture.api.signIns, [('erik@example.com', 'correct horse')]);
      expect(fixture.controller.value.step, OnboardingStep.permissions);
      expect(fixture.controller.value.error, isNull);
      expect(
        fixture.preferences.getInt(OnboardingController.highestStepKey),
        OnboardingStep.signIn.index,
      );
    });

    test('goBack from permissions returns to the email form, not the welcome', () async {
      final fixture = _Fixture(configured: true, highestStep: OnboardingStep.signIn.index);
      await fixture.controller.initialize();
      expect(fixture.controller.value.step, OnboardingStep.permissions);

      fixture.controller.goBack();

      expect(fixture.controller.value.step, OnboardingStep.signIn);
      expect(fixture.controller.value.showWelcome, isFalse);
    });

    test('a completed legacy install skips sign-in', () async {
      // The owner's phone before the update: a pasted key, setup done
      final fixture = _Fixture(
        configured: true,
        hasIdentity: true,
        highestStep: 3,
        completed: true,
      );

      await fixture.controller.initialize();

      expect(fixture.controller.value.completed, isTrue);
      expect(fixture.api.signInCalls, 0);
    });

    test('privacy goes to first result only when paired', () async {
      final paired = _Fixture(
        configured: true,
        hasIdentity: true,
        highestStep: OnboardingStep.pairing.index,
      );
      await paired.controller.initialize();
      await paired.controller.finishPrivacy();
      expect(paired.controller.value.step, OnboardingStep.firstResult);
      expect(paired.controller.value.completed, isFalse);

      final unpaired = _Fixture(
        configured: true,
        highestStep: OnboardingStep.pairing.index,
      );
      await unpaired.controller.initialize();
      await unpaired.controller.finishPrivacy();
      expect(unpaired.controller.value.completed, isTrue);
    });

    test('Bluetooth denial blocks remaining permission requests', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.signIn.index,
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
        highestStep: OnboardingStep.signIn.index,
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
        highestStep: OnboardingStep.signIn.index,
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
        highestStep: OnboardingStep.signIn.index,
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
      expect(backend.controller.value.step, OnboardingStep.signIn);

      final permissions = _Fixture(
        configured: true,
        highestStep: OnboardingStep.signIn.index,
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

      expect(fixture.controller.value.step, OnboardingStep.signIn);
      expect(fixture.controller.value.showWelcome, isTrue);
      expect(fixture.controller.value.completed, isFalse);
    });

    test('completed onboarding without a device resumes as complete', () async {
      final fixture = _Fixture(
        configured: true,
        hasIdentity: false,
        highestStep: OnboardingStep.privacy.index,
        completed: true,
      );

      await fixture.controller.initialize();

      expect(fixture.controller.value.step, OnboardingStep.privacy);
      expect(fixture.controller.value.completed, isTrue);
      expect(fixture.controller.value.paired, isFalse);
    });

    test('skipping pairing finishes setup without a device', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.permissions.index,
      );
      await fixture.controller.initialize();
      expect(fixture.controller.value.step, OnboardingStep.pairing);

      await fixture.controller.skipPairing();

      expect(fixture.controller.value.step, OnboardingStep.privacy);
      expect(fixture.controller.value.paired, isFalse);
      expect(fixture.pairing.pairCalls, 0);
      expect(
        fixture.preferences.getInt(OnboardingController.highestStepKey),
        OnboardingStep.pairing.index,
      );

      await fixture.controller.complete();
      expect(fixture.controller.value.completed, isTrue);
    });

    test('skipped pairing is not asked again on the next launch', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.pairing.index,
      );

      await fixture.controller.initialize();

      expect(fixture.controller.value.step, OnboardingStep.privacy);
      expect(fixture.controller.value.paired, isFalse);
    });

    test('pairing later from Settings reopens the pairing step', () async {
      final fixture = _Fixture(
        configured: true,
        highestStep: OnboardingStep.privacy.index,
        completed: true,
      );

      await fixture.controller.initialize(resumePairingIfConfigured: true);

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
      highestStep: OnboardingStep.signIn.index,
    );

    await _pumpOnboarding(tester, fixture.controller);

    expect(find.text('What Echo needs'), findsOneWidget);
    expect(fixture.permissions.totalCalls, 0);
  });

  testWidgets('final CTA persists and invokes completion callback',
      (tester) async {
    // Without a paired Echo there is no first result to wait for
    final fixture = _Fixture(
      configured: true,
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

  testWidgets('pairing can be skipped without a device', (tester) async {
    final fixture = _Fixture(
      configured: true,
      highestStep: OnboardingStep.permissions.index,
    );

    await _pumpOnboarding(tester, fixture.controller);
    await tester.tap(find.byKey(const Key('onboarding-skip-pairing')));
    await tester.pumpAndSettle();

    expect(fixture.controller.value.step, OnboardingStep.privacy);
    expect(find.text('Start using Echo'), findsOneWidget);
    expect(find.byKey(const Key('onboarding-skip-pairing')), findsNothing);
  });

  testWidgets('a fresh install asks to sign in, never for a server',
      (tester) async {
    final fixture = _Fixture();

    await _pumpOnboarding(tester, fixture.controller);
    await tester.tap(find.byKey(const Key('welcome-email')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sign-in-email')), findsOneWidget);
    expect(find.byKey(const Key('sign-in-password')), findsOneWidget);
    expect(find.textContaining('https://'), findsNothing);
    expect(find.textContaining('API key'), findsNothing);
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
    expect(find.byKey(const Key('welcome-email')), findsOneWidget);
  });

  group('welcome and sign-in', () {
    testWidgets('Apple and Google say they are coming', (tester) async {
      await _pumpOnboarding(tester, _Fixture().controller);

      await tester.tap(find.byKey(const Key('welcome-apple')));
      await tester.pumpAndSettle();
      expect(
        find.text('Sign in with Apple is coming soon. For now, continue with email.'),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('welcome-google')));
      await tester.pumpAndSettle();
      expect(
        find.text('Sign in with Google is coming soon. For now, continue with email.'),
        findsOneWidget,
      );
    });

    testWidgets('email form signs in and shows the server\'s message on failure',
        (tester) async {
      final fixture = _Fixture();
      fixture.api.signInError = const SignInException(
        SignInFailure.wrongCredentials,
        'Wrong email or password.',
      );
      await _pumpOnboarding(tester, fixture.controller);
      await tester.tap(find.byKey(const Key('welcome-email')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('sign-in-email')), 'erik@example.com');
      await tester.enterText(find.byKey(const Key('sign-in-password')), 'not it');
      await tester.tap(find.byKey(const Key('sign-in-submit')));
      await tester.pumpAndSettle();

      expect(fixture.api.signIns, [('erik@example.com', 'not it')]);
      expect(find.text('Wrong email or password.'), findsOneWidget);

      fixture.api.signInError = null;
      await tester.tap(find.byKey(const Key('sign-in-submit')));
      await tester.pumpAndSettle();
      expect(fixture.controller.value.step, OnboardingStep.permissions);
    });

    testWidgets('forgot password explains the reset', (tester) async {
      await _pumpOnboarding(tester, _Fixture().controller);
      await tester.tap(find.byKey(const Key('welcome-email')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sign-in-forgot')));
      await tester.pumpAndSettle();

      expect(
        find.text('For now, a password is reset by whoever runs your Echo server.'),
        findsOneWidget,
      );
    });

    testWidgets('reduced motion keeps the welcome still and shows both memories',
        (tester) async {
      await _pumpOnboarding(tester, _Fixture().controller);

      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.text('Both options, Thu'), findsOneWidget);
      expect(find.text('Lunch, Tue 13:00'), findsOneWidget);
      expect(find.text('Your day,\nremembered.'), findsOneWidget);

      // With motion on, the welcome keeps animating
      await tester.pumpWidget(const SizedBox());
      await _pumpOnboarding(
        tester,
        _Fixture().controller,
        disableAnimations: false,
        settle: false,
      );
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the welcome fits 320x640 at 1.3 text scale, light and dark',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        await _pumpOnboarding(
          tester,
          _Fixture().controller,
          textScaler: const TextScaler.linear(1.3),
          themeMode: mode,
          notice: 'This phone was signed out.',
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('progress shows steps 1–4 on email, permissions, pairing and privacy',
        (tester) async {
      final fixture = _Fixture();
      await _pumpOnboarding(tester, fixture.controller);
      expect(find.byKey(const Key('onboarding-progress')), findsNothing);

      await tester.tap(find.byKey(const Key('welcome-email')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Step 1 of 4'), findsOneWidget);

      await fixture.controller.signIn('erik@example.com', 'correct horse');
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Step 2 of 4'), findsOneWidget);

      await fixture.controller.requestPermissions();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Step 3 of 4'), findsOneWidget);

      await fixture.controller.skipPairing();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Step 4 of 4'), findsOneWidget);
    });

    testWidgets('a revoked phone sees why on the welcome', (tester) async {
      await _pumpOnboarding(
        tester,
        _Fixture().controller,
        notice: 'This phone was signed out.',
      );

      expect(find.text('This phone was signed out.'), findsOneWidget);
    });
  });
}

/// The welcome moves for ever: still by default, so pumpAndSettle settles.
Future<void> _pumpOnboarding(
  WidgetTester tester,
  OnboardingController controller, {
  VoidCallback? onComplete,
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = true,
  ThemeMode themeMode = ThemeMode.light,
  String? notice,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      home: MediaQuery(
        data: MediaQueryData(
          textScaler: textScaler,
          disableAnimations: disableAnimations,
        ),
        child: OnboardingScreen(
          controller: controller,
          onComplete: onComplete ?? () {},
          notice: notice,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
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
  SignInException? signInError;
  final signIns = <(String, String)>[];

  int get signInCalls => signIns.length;

  @override
  Future<bool> isConfigured() async => configured;

  @override
  Future<void> signIn(String email, String password) async {
    signIns.add((email, password));
    if (signInError case final error?) throw error;
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