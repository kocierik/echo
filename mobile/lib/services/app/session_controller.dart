import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/session_state.dart';
import '../api/api_service.dart';
import '../device/device_controller.dart';
import '../device/device_identity_store.dart';
import '../api/response_cache.dart';

export '../../models/session_state.dart';

abstract interface class ApiCredentialsClearer {
  /// Throws [ServerSignOutFailed] when the phone was cleared but the server
  /// could not be told.
  Future<void> clear();
}

/// The phone signed out, but its key could not be deleted on the server: it keeps
/// working there until revoked from another phone.
final class ServerSignOutFailed implements Exception {
  const ServerSignOutFailed();

  static const notice = "Signed out here, but Echo's server could not be reached. "
      'Revoke this phone from Settings → Devices on another one.';
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
    Stream<void>? unauthorized,
  })  : _bleStopper = bleStopper,
        _apiCredentials = apiCredentials,
        _deviceIdentity = deviceIdentity,
        _sessionCache = sessionCache {
    _unauthorized = unauthorized?.listen((_) => unawaited(signOutRevoked()));
  }

  /// Said on the welcome after a key was revoked from another phone.
  static const revokedReason = 'This phone was signed out.';

  final ActiveBleStopper _bleStopper;
  final ApiCredentialsClearer _apiCredentials;
  final DeviceIdentityClearer _deviceIdentity;
  final SessionCacheClearer _sessionCache;
  final _stateController = StreamController<SessionState>.broadcast();
  StreamSubscription<void>? _unauthorized;

  SessionState _state = const SessionState(SessionStatus.loggedIn);
  SessionState get state => _state;
  Stream<SessionState> get stream => _stateController.stream;

  /// Signs this phone out: its key on the server, then everything on the phone.
  Future<void> logout({String? reason}) async {
    if (_state.loggingOut || _state.loggedOut) return;
    _setState(SessionState(SessionStatus.loggingOut, reason: reason));

    final errors = <String>[];
    var serverMissed = false;
    await _attempt('BLE stop', _bleStopper.stop, errors);
    await _attempt('API credentials', () async {
      try {
        await _apiCredentials.clear();
      } on ServerSignOutFailed {
        serverMissed = true;
      }
    }, errors);
    // A reason given (a revoked key) wins: that key is dead on the server anyway
    reason ??= serverMissed ? ServerSignOutFailed.notice : null;
    await _attempt('device identity', _deviceIdentity.clear, errors);
    await _attempt('session cache', _sessionCache.clear, errors);

    if (errors.isEmpty) {
      _setState(SessionState(SessionStatus.loggedOut, reason: reason));
    } else {
      _setState(SessionState(
        SessionStatus.cleanupFailed,
        error: 'Logout cleanup failed: ${errors.join('; ')}',
        reason: reason,
      ));
    }
  }

  /// The key was revoked from another phone: sign out once, saying why.
  Future<void> signOutRevoked() => logout(reason: revokedReason);

  /// Signed in again (the first run is done): a later logout or revoked key counts.
  void markSignedIn() {
    if (_state.loggedIn) return;
    _setState(const SessionState(SessionStatus.loggedIn));
  }

  Future<void> dispose() async {
    await _unauthorized?.cancel();
    await _stateController.close();
  }

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

  /// Deletes the phone's key on the server first; not reaching it never blocks the
  /// logout on the phone.
  @override
  Future<void> clear() async {
    var reached = true;
    try {
      await _apiService.signOutThisPhone();
    } catch (_) {
      reached = false;
    }
    await _apiService.clearConfiguration();
    if (!reached) throw const ServerSignOutFailed();
  }
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
    // The language the account speaks (SpokenLanguageStore.key)
    'spoken_language',
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