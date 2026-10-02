import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/session_state.dart';
import 'package:echo_app/services/app_controller.dart';
import 'package:echo_app/services/onboarding_controller.dart';
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
    await tester.pumpAndSettle();

    expect(find.text('Connect your backend'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);
    expect(find.text('Connect backend'), findsOneWidget);
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
  Future<void> configure(String serverUrl, String apiKey) async {}

  @override
  Future<bool> isConfigured() async => false;

  @override
  Future<bool> validateCredentials(String serverUrl, String apiKey) async {
    return true;
  }
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
