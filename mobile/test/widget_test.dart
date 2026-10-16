import 'dart:async';

import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/session_state.dart';
import 'package:echo_app/services/app/app_controller.dart';
import 'package:echo_app/services/onboarding/onboarding_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/main.dart';

void main() {
  testWidgets('shows onboarding when Echo is not configured', (tester) async {
    final preferences = _FakeAppPreferences();
    final appController = AppController(
      initialDevice: const DeviceStatus(
        connectionState: DeviceConnectionState.unpaired,
      ),
      deviceStates: const Stream<DeviceStatus>.empty(),
      initialSession: const SessionState(SessionStatus.loggedIn),
      sessionStates: const Stream<SessionState>.empty(),
      preferences: preferences,
    );
    final onboardingController = OnboardingController(
      api: _FakeOnboardingApi(),
      permissions: _FakeOnboardingPermissions(),
      pairing: _FakeOnboardingPairing(),
      preferences: preferences,
    );
    await appController.initialize();
    addTearDown(appController.dispose);

    await tester.pumpWidget(EchoApp(
      appController: appController,
      onboardingControllerFactory: () => onboardingController,
    ));
    // The welcome keeps moving: step through the loading instead of settling
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // A fresh install opens on the welcome; no server or key is ever asked
    expect(find.byKey(const Key('welcome-email')), findsOneWidget);
    expect(find.text('Server URL'), findsNothing);
    expect(find.text('API Key'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a sign-out closes every open page', (tester) async {
    final preferences = _FakeAppPreferences();
    final sessions = StreamController<SessionState>.broadcast();
    addTearDown(sessions.close);
    final appController = AppController(
      initialDevice: const DeviceStatus(
        connectionState: DeviceConnectionState.unpaired,
      ),
      deviceStates: const Stream<DeviceStatus>.empty(),
      initialSession: const SessionState(SessionStatus.loggedIn),
      sessionStates: sessions.stream,
      preferences: preferences,
    );
    await appController.initialize();
    addTearDown(appController.dispose);
    OnboardingController onboarding() => OnboardingController(
          api: _FakeOnboardingApi(),
          permissions: _FakeOnboardingPermissions(),
          pairing: _FakeOnboardingPairing(),
          preferences: preferences,
        );

    await tester.pumpWidget(EchoApp(
      appController: appController,
      onboardingControllerFactory: onboarding,
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // A page open on top, like Settings
    unawaited(Navigator.of(tester.element(find.byKey(const Key('welcome-email')))).push(
          PageRouteBuilder<void>(pageBuilder: (_, __, ___) => const Text('A page on top')),
        ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('A page on top'), findsOneWidget);

    sessions.add(const SessionState(
      SessionStatus.loggedOut,
      reason: 'This phone was signed out.',
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('A page on top'), findsNothing);
    expect(find.text('This phone was signed out.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('signing in again does not rebuild the app from scratch', (tester) async {
    final preferences = _FakeAppPreferences();
    final sessions = StreamController<SessionState>.broadcast();
    addTearDown(sessions.close);
    final appController = AppController(
      initialDevice: const DeviceStatus(connectionState: DeviceConnectionState.unpaired),
      deviceStates: const Stream<DeviceStatus>.empty(),
      initialSession: const SessionState(SessionStatus.loggedIn),
      sessionStates: sessions.stream,
      preferences: preferences,
    );
    await appController.initialize();
    addTearDown(appController.dispose);
    var made = 0;
    OnboardingController onboarding() {
      made++;
      return OnboardingController(
        api: _FakeOnboardingApi(),
        permissions: _FakeOnboardingPermissions(),
        pairing: _FakeOnboardingPairing(),
        preferences: preferences,
      );
    }

    await tester.pumpWidget(EchoApp(appController: appController, onboardingControllerFactory: onboarding));
    await tester.pump(const Duration(milliseconds: 300));
    expect(made, 1);

    sessions.add(const SessionState(SessionStatus.loggedOut));
    await tester.pump(const Duration(milliseconds: 300));
    expect(made, 2); // setup starts over

    sessions.add(const SessionState(SessionStatus.loggedIn));
    await tester.pump(const Duration(milliseconds: 300));
    expect(made, 2); // back in: nothing is thrown away
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed cleanup after a revoked key says so and offers to retry',
      (tester) async {
    final preferences = _FakeAppPreferences();
    final appController = AppController(
      initialDevice: const DeviceStatus(connectionState: DeviceConnectionState.unpaired),
      deviceStates: const Stream<DeviceStatus>.empty(),
      initialSession: const SessionState(
        SessionStatus.cleanupFailed,
        error: 'Logout cleanup failed: API credentials: keychain locked',
        reason: 'This phone was signed out.',
      ),
      sessionStates: const Stream<SessionState>.empty(),
      preferences: preferences,
    );
    await appController.initialize();
    addTearDown(appController.dispose);

    await tester.pumpWidget(EchoApp(
      appController: appController,
      onboardingControllerFactory: () => OnboardingController(
        api: _FakeOnboardingApi(),
        permissions: _FakeOnboardingPermissions(),
        pairing: _FakeOnboardingPairing(),
        preferences: preferences,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('This phone was signed out.'), findsOneWidget);
    expect(find.byKey(const Key('signed-out-retry')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
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

final class _FakeOnboardingApi implements OnboardingApi {
  @override
  Future<bool> isConfigured() async => false;

  @override
  Future<void> signIn(String email, String password) async {}
}

final class _FakeOnboardingPermissions implements OnboardingPermissions {
  @override
  String get backgroundCapabilityExplanation => 'Background access details.';

  @override
  Future<bool> requestBluetooth() async => true;

  @override
  Future<bool> requestNotifications() async => true;

  @override
  Future<bool> requestVoiceMicrophone() async => true;
}

final class _FakeOnboardingPairing implements OnboardingPairing {
  @override
  Future<bool> hasIdentity() async => false;

  @override
  Future<void> pair() async {}
}
