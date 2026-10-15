import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/session_state.dart';
import '../api/api_service.dart';
import '../device/device_controller.dart';
import '../device/device_identity_store.dart';
import '../api/response_cache.dart';

export '../../models/session_state.dart';

abstract interface class ApiCredentialsClearer {
  Future<void> clear();
}

abstract interface class DeviceIdentityClearer {
  Future<void> clear();
}

abstract interface class SessionCacheClearer {
  Future<void> clear();
}

abstract interface class ActiveBleStopper {
  Future<void> stop();
}

final class SessionController {
  SessionController({
    required ActiveBleStopper bleStopper,
    required ApiCredentialsClearer apiCredentials,
    required DeviceIdentityClearer deviceIdentity,
    required SessionCacheClearer sessionCache,
  })  : _bleStopper = bleStopper,
        _apiCredentials = apiCredentials,
        _deviceIdentity = deviceIdentity,
        _sessionCache = sessionCache;

  final ActiveBleStopper _bleStopper;
  final ApiCredentialsClearer _apiCredentials;
  final DeviceIdentityClearer _deviceIdentity;
  final SessionCacheClearer _sessionCache;
  final _stateController = StreamController<SessionState>.broadcast();

  SessionState _state = const SessionState(SessionStatus.loggedIn);
  SessionState get state => _state;
  Stream<SessionState> get stream => _stateController.stream;

  Future<void> logout() async {
    if (_state.loggingOut || _state.loggedOut) return;
    _setState(const SessionState(SessionStatus.loggingOut));

    final errors = <String>[];
    await _attempt('BLE stop', _bleStopper.stop, errors);
    await _attempt('API credentials', _apiCredentials.clear, errors);
    await _attempt('device identity', _deviceIdentity.clear, errors);
    await _attempt('session cache', _sessionCache.clear, errors);

    if (errors.isEmpty) {
      _setState(const SessionState(SessionStatus.loggedOut));
    } else {
      _setState(SessionState(
        SessionStatus.cleanupFailed,
        error: 'Logout cleanup failed: ${errors.join('; ')}',
      ));
    }
  }

  Future<void> dispose() => _stateController.close();

  Future<void> _attempt(
    String label,
    Future<void> Function() action,
    List<String> errors,
  ) async {
    try {
      await action();
    } catch (error) {
      errors.add('$label: $error');
    }
  }

  void _setState(SessionState state) {
    _state = state;
    _stateController.add(state);
  }
}

final class ApiServiceCredentialsClearer implements ApiCredentialsClearer {
  const ApiServiceCredentialsClearer(this._apiService);

  final ApiService _apiService;

  @override
  Future<void> clear() => _apiService.clearConfiguration();
}

final class DeviceIdentityStoreClearer implements DeviceIdentityClearer {
  const DeviceIdentityStoreClearer(this._identityStore);

  final DeviceIdentityStorePort _identityStore;

  @override
  Future<void> clear() => _identityStore.clear();
}

final class DeviceControllerBleStopper implements ActiveBleStopper {
  const DeviceControllerBleStopper(this._deviceController);

  final DeviceController _deviceController;

  @override
  Future<void> stop() => _deviceController.disconnect();
}

final class SharedPreferencesSessionCacheClearer
    implements SessionCacheClearer {
  const SharedPreferencesSessionCacheClearer(this._preferences, {this.responses});

  static const knownKeys = <String>{
    'echo_theme_mode',
    'echo_selected_tab',
    'echo_onboarding_complete',
    'onboarding_highest_completed_step',
    'onboarding_complete',
    'echo_network_policy',
    'echo_allow_cellular',
    'echo_last_session_id',
    'notify_briefings',
    'notify_promises',
    'notify_evening',
  };

  final SharedPreferences _preferences;

  /// The offline copy of the server's answers: the user's memory, gone on logout.
  final ResponseCache? responses;

  @override
  Future<void> clear() async {
    Object? firstError;
    for (final key in knownKeys) {
      try {
        await _preferences.remove(key);
      } catch (error) {
        firstError ??= error;
      }
    }
    try {
      await responses?.clear();
    } catch (error) {
      firstError ??= error;
    }
    if (firstError != null) {
      throw StateError('Failed to clear session cache: $firstError');
    }
  }
}