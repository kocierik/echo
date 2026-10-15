import '../api/api_service.dart';
import '../device/device_controller.dart';
import 'onboarding_controller.dart';

final class ApiServiceOnboardingApi implements OnboardingApi {
  const ApiServiceOnboardingApi(this._api);

  final ApiService _api;

  @override
  Future<bool> isConfigured() => _api.isConfigured();

  @override
  Future<bool> validateCredentials(String serverUrl, String apiKey) {
    return _api.validateCredentials(serverUrl, apiKey);
  }

  @override
  Future<void> configure(String serverUrl, String apiKey) {
    return _api.configure(serverUrl, apiKey);
  }
}

final class DeviceControllerOnboardingPairing implements OnboardingPairing {
  const DeviceControllerOnboardingPairing({
    required DeviceController deviceController,
    required Future<bool> Function() hasIdentity,
  })  : _deviceController = deviceController,
        _hasIdentity = hasIdentity;

  final DeviceController _deviceController;
  final Future<bool> Function() _hasIdentity;

  @override
  Future<bool> hasIdentity() => _hasIdentity();

  @override
  Future<void> pair() => _deviceController.pair();
}