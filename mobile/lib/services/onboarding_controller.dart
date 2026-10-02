import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_preferences.dart';

enum OnboardingStep { backend, permissions, pairing, privacy }

abstract interface class OnboardingApi {
  Future<bool> isConfigured();
  Future<bool> validateCredentials(String serverUrl, String apiKey);
  Future<void> configure(String serverUrl, String apiKey);
}

abstract interface class OnboardingPermissions {
  String get backgroundCapabilityExplanation;
  Future<bool> requestBluetooth();
  Future<bool> requestNotifications();
  Future<bool> requestVoiceMicrophone();
}

abstract interface class OnboardingPairing {
  Future<bool> hasIdentity();
  Future<void> pair();
}

@immutable
final class OnboardingState {
  const OnboardingState({
    required this.step,
    required this.busy,
    required this.initialized,
    required this.completed,
    required this.notificationDenied,
    required this.voiceDenied,
    required this.paired,
    this.error,
  });

  const OnboardingState.initial()
      : step = OnboardingStep.backend,
        busy = true,
        initialized = false,
        completed = false,
        notificationDenied = false,
        voiceDenied = false,
        paired = false,
        error = null;

  final OnboardingStep step;
  final bool busy;
  final bool initialized;
  final bool completed;
  final bool notificationDenied;
  final bool voiceDenied;
  final bool paired;
  final String? error;

  OnboardingState copyWith({
    OnboardingStep? step,
    bool? busy,
    bool? initialized,
    bool? completed,
    bool? notificationDenied,
    bool? voiceDenied,
    bool? paired,
    Object? error = _unchanged,
  }) {
    return OnboardingState(
      step: step ?? this.step,
      busy: busy ?? this.busy,
      initialized: initialized ?? this.initialized,
      completed: completed ?? this.completed,
      notificationDenied: notificationDenied ?? this.notificationDenied,
      voiceDenied: voiceDenied ?? this.voiceDenied,
      paired: paired ?? this.paired,
      error: identical(error, _unchanged) ? this.error : error as String?,
    );
  }
}

const Object _unchanged = Object();

final class OnboardingController extends ValueNotifier<OnboardingState> {
  OnboardingController({
    required OnboardingApi api,
    required OnboardingPermissions permissions,
    required OnboardingPairing pairing,
    required AppPreferences preferences,
    VoidCallback? onDispose,
  })  : _api = api,
        _permissions = permissions,
        _pairing = pairing,
        _preferences = preferences,
        _onDispose = onDispose,
        super(const OnboardingState.initial());

  static const String highestStepKey = 'onboarding_highest_completed_step';
  static const String completedKey = 'onboarding_complete';

  final OnboardingApi _api;
  final OnboardingPermissions _permissions;
  final OnboardingPairing _pairing;
  final AppPreferences _preferences;
  final VoidCallback? _onDispose;

  Future<void>? _initializing;
  bool _disposed = false;

  String get backgroundCapabilityExplanation =>
      _permissions.backgroundCapabilityExplanation;

  Future<void> initialize({bool resumePairingIfConfigured = false}) {
    return _initializing ??= _initialize(resumePairingIfConfigured);
  }

  Future<void> _initialize(bool resumePairingIfConfigured) async {
    try {
      final configured = await _api.isConfigured();
      if (_disposed) return;
      final storedHighest = _preferences.getInt(highestStepKey) ?? -1;
      final highest = storedHighest.clamp(-1, OnboardingStep.values.length - 1);
      final completionStored = _preferences.getBool(completedKey) ?? false;

      if (!configured) {
        _setReady(OnboardingStep.backend);
        return;
      }

      if (resumePairingIfConfigured) {
        final hasIdentity = await _pairing.hasIdentity();
        if (_disposed) return;
        if (!hasIdentity) {
          await _persistHighest(OnboardingStep.permissions);
          if (_disposed) return;
          _setReady(OnboardingStep.pairing);
          return;
        }
      }

      var effectiveHighest = highest;
      if (effectiveHighest < OnboardingStep.backend.index) {
        await _persistHighest(OnboardingStep.backend);
        effectiveHighest = OnboardingStep.backend.index;
      }
      if (_disposed) return;
      if (effectiveHighest < OnboardingStep.permissions.index) {
        _setReady(OnboardingStep.permissions);
        return;
      }

      final hasIdentity = await _pairing.hasIdentity();
      if (_disposed) return;
      if (!hasIdentity) {
        _setReady(OnboardingStep.pairing);
        return;
      }

      if (effectiveHighest < OnboardingStep.pairing.index) {
        await _persistHighest(OnboardingStep.pairing);
        effectiveHighest = OnboardingStep.pairing.index;
      }
      if (_disposed) return;
      if (effectiveHighest >= OnboardingStep.privacy.index &&
          completionStored) {
        value = value.copyWith(
          step: OnboardingStep.privacy,
          busy: false,
          initialized: true,
          completed: true,
          paired: true,
          error: null,
        );
        return;
      }
      _setReady(OnboardingStep.privacy, paired: true);
    } catch (_) {
      if (_disposed) return;
      value = value.copyWith(
        step: OnboardingStep.backend,
        busy: false,
        initialized: true,
        completed: false,
        error: 'Echo could not load setup progress. Try again.',
      );
    }
  }

  Future<void> submitBackend(String serverUrl, String apiKey) async {
    if (value.busy || _disposed) return;
    final server = serverUrl.trim();
    final key = apiKey.trim();
    if (server.isEmpty || key.isEmpty) {
      value = value.copyWith(error: 'Server URL and API key are required.');
      return;
    }

    _setBusy();
    try {
      final valid = await _api.validateCredentials(server, key);
      if (_disposed) return;
      if (!valid) {
        _setError('Connection failed. Check the server URL and API key.');
        return;
      }
      await _api.configure(server, key);
      if (_disposed) return;
      await _persistHighest(OnboardingStep.backend);
      if (_disposed) return;
      value = value.copyWith(
        step: OnboardingStep.permissions,
        busy: false,
        completed: false,
        error: null,
      );
    } catch (_) {
      _setError('Connection failed. Check the server URL and try again.');
    }
  }

  Future<void> requestPermissions() async {
    if (value.busy || _disposed) return;
    _setBusy();
    try {
      final bluetoothGranted = await _permissions.requestBluetooth();
      if (_disposed) return;
      if (!bluetoothGranted) {
        _setError('Bluetooth access is required to connect your Echo.');
        return;
      }
    } catch (_) {
      _setError('Bluetooth is unavailable. Turn it on and try again.');
      return;
    }

    var notificationDenied = false;
    var voiceDenied = false;
    try {
      notificationDenied = !await _permissions.requestNotifications();
    } catch (_) {
      notificationDenied = true;
    }
    if (_disposed) return;
    try {
      voiceDenied = !await _permissions.requestVoiceMicrophone();
    } catch (_) {
      voiceDenied = true;
    }
    if (_disposed) return;

    try {
      await _persistHighest(OnboardingStep.permissions);
      if (_disposed) return;
      value = value.copyWith(
        step: OnboardingStep.pairing,
        busy: false,
        completed: false,
        notificationDenied: notificationDenied,
        voiceDenied: voiceDenied,
        error: null,
      );
    } catch (_) {
      _setError('Echo could not save permission progress. Try again.');
    }
  }

  Future<void> pair() async {
    if (value.busy || _disposed) return;
    _setBusy();
    try {
      await _pairing.pair();
      if (_disposed) return;
      final paired = await _pairing.hasIdentity();
      if (_disposed) return;
      if (!paired) {
        _setError('No Echo was found. Keep it nearby and try again.');
        return;
      }
      await _persistHighest(OnboardingStep.pairing);
      if (_disposed) return;
      value = value.copyWith(
        step: OnboardingStep.privacy,
        busy: false,
        completed: false,
        paired: true,
        error: null,
      );
    } catch (error) {
      final detail = error is StateError ? error.message : null;
      _setError(
        detail == null || detail.isEmpty
            ? 'No Echo was found. Keep it nearby and try again.'
            : detail,
      );
    }
  }

  Future<void> complete() async {
    if (value.busy || _disposed) return;
    _setBusy();
    try {
      await _persistHighest(OnboardingStep.privacy);
      final saved = await _preferences.setBool(completedKey, true);
      if (!saved) throw StateError('Completion was not saved');
      if (_disposed) return;
      value = value.copyWith(
        busy: false,
        completed: true,
        error: null,
      );
    } catch (_) {
      _setError('Echo could not finish setup. Try again.');
    }
  }

  void goBack() {
    if (value.busy || _disposed || value.step == OnboardingStep.backend) return;
    value = value.copyWith(
      step: OnboardingStep.values[value.step.index - 1],
      error: null,
    );
  }

  Future<void> _persistHighest(OnboardingStep step) async {
    final current = _preferences.getInt(highestStepKey) ?? -1;
    if (current >= step.index) return;
    final saved = await _preferences.setInt(highestStepKey, step.index);
    if (!saved) throw StateError('Progress was not saved');
  }

  void _setReady(OnboardingStep step, {bool paired = false}) {
    if (_disposed) return;
    value = value.copyWith(
      step: step,
      busy: false,
      initialized: true,
      completed: false,
      paired: paired,
      error: null,
    );
  }

  void _setBusy() {
    value = value.copyWith(busy: true, error: null);
  }

  void _setError(String message) {
    if (_disposed) return;
    value = value.copyWith(busy: false, error: message);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _onDispose?.call();
    super.dispose();
  }
}