import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/auth_api.dart';
import '../app/app_preferences.dart';

/// The first run, in order. The first four keep their indexes (the stored progress
/// predates sign-in, when the first step was the server).
enum OnboardingStep { signIn, permissions, pairing, privacy, firstResult }

abstract interface class OnboardingApi {
  Future<bool> isConfigured();

  /// Throws [SignInException] with the message to show.
  Future<void> signIn(String email, String password);

  /// A new account, this phone signed in to it; throws [SignInException].
  Future<void> register(String email, String password);
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
    this.showWelcome = true,
    this.creatingAccount = false,
    this.error,
  });

  const OnboardingState.initial()
      : step = OnboardingStep.signIn,
        showWelcome = true,
        creatingAccount = false,
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

  /// On [OnboardingStep.signIn]: the welcome, until "Continue with email".
  final bool showWelcome;

  /// On the email form: creating an account rather than signing in.
  final bool creatingAccount;
  final String? error;

  OnboardingState copyWith({
    OnboardingStep? step,
    bool? busy,
    bool? initialized,
    bool? completed,
    bool? notificationDenied,
    bool? voiceDenied,
    bool? paired,
    bool? showWelcome,
    bool? creatingAccount,
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
      showWelcome: showWelcome ?? this.showWelcome,
      creatingAccount: creatingAccount ?? this.creatingAccount,
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
    ({String email, String password})? devAccount,
  })  : _api = api,
        _devAccount = devAccount,
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

  /// A debug build's test account (BuildDefaults.devAccount): signed in by itself.
  final ({String email, String password})? _devAccount;

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
        _setReady(OnboardingStep.signIn);
        final dev = _devAccount;
        if (dev != null) {
          value = value.copyWith(showWelcome: false);
          await signIn(dev.email, dev.password);
          if (_disposed || value.step != OnboardingStep.signIn) return;
        }
        // The welcome; after a refused test account, with why
        value = value.copyWith(showWelcome: true);
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
      if (effectiveHighest < OnboardingStep.signIn.index) {
        await _persistHighest(OnboardingStep.signIn);
        effectiveHighest = OnboardingStep.signIn.index;
      }
      if (_disposed) return;
      if (effectiveHighest < OnboardingStep.permissions.index) {
        _setReady(OnboardingStep.permissions);
        return;
      }

      final hasIdentity = await _pairing.hasIdentity();
      if (_disposed) return;
      // Past the pairing step without an identity means pairing was skipped:
      // the app opens without a device, which is paired later from Settings.
      if (!hasIdentity && effectiveHighest < OnboardingStep.pairing.index) {
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
          paired: hasIdentity,
          error: null,
        );
        return;
      }
      _setReady(OnboardingStep.privacy, paired: hasIdentity);
    } catch (_) {
      if (_disposed) return;
      value = value.copyWith(
        step: OnboardingStep.signIn,
        busy: false,
        initialized: true,
        completed: false,
        error: 'Echo could not load setup progress. Try again.',
      );
    }
  }

  /// From the welcome to the email form.
  void continueWithEmail() {
    if (_disposed || value.step != OnboardingStep.signIn) return;
    value = value.copyWith(showWelcome: false, error: null);
  }

  void backToWelcome() {
    if (_disposed || value.busy || value.step != OnboardingStep.signIn) return;
    value = value.copyWith(showWelcome: true, error: null);
  }

  /// The email form switches to creating an account…
  void showCreateAccount() {
    if (_disposed || value.busy || value.step != OnboardingStep.signIn) return;
    value = value.copyWith(creatingAccount: true, showWelcome: false, error: null);
  }

  /// …and back to signing in.
  void showSignIn() {
    if (_disposed || value.busy || value.step != OnboardingStep.signIn) return;
    value = value.copyWith(creatingAccount: false, error: null);
  }

  Future<void> signIn(String email, String password) => _enter(email, password, _api.signIn);

  Future<void> createAccount(String email, String password) =>
      _enter(email, password, _api.register);

  Future<void> _enter(
    String email,
    String password,
    Future<void> Function(String email, String password) call,
  ) async {
    if (value.busy || _disposed) return;
    final address = email.trim();
    if (address.isEmpty || password.isEmpty) {
      value = value.copyWith(error: 'Enter your email and password.');
      return;
    }
    _setBusy();
    try {
      await call(address, password);
      if (_disposed) return;
      await _persistHighest(OnboardingStep.signIn);
      if (_disposed) return;
      // The browser has no wearable, Bluetooth or phone permissions: setup ends here
      if (kIsWeb) {
        value = value.copyWith(busy: false, error: null);
        return complete();
      }
      value = value.copyWith(
        step: OnboardingStep.permissions,
        busy: false,
        completed: false,
        error: null,
      );
    } on SignInException catch (error) {
      _setError(error.message);
    } catch (_) {
      _setError('Echo could not sign you in. Try again.');
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

  /// Leaves pairing for later: setup finishes without a device.
  Future<void> skipPairing() async {
    if (value.busy || _disposed || value.step != OnboardingStep.pairing) return;
    _setBusy();
    try {
      await _persistHighest(OnboardingStep.pairing);
      if (_disposed) return;
      value = value.copyWith(
        step: OnboardingStep.privacy,
        busy: false,
        completed: false,
        paired: false,
        error: null,
      );
    } catch (_) {
      _setError('Echo could not save setup progress. Try again.');
    }
  }

  /// The last setup step: a paired Echo can show a first result, else setup is done.
  Future<void> finishPrivacy() async {
    if (value.busy || _disposed) return;
    if (!value.paired) return complete();
    try {
      await _persistHighest(OnboardingStep.privacy);
    } catch (_) {
      _setError('Echo could not finish setup. Try again.');
      return;
    }
    if (_disposed) return;
    value = value.copyWith(step: OnboardingStep.firstResult, error: null);
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
    if (value.busy || _disposed) return;
    if (value.step == OnboardingStep.signIn) return backToWelcome();
    // Back from permissions is the email form, already filled in
    value = value.copyWith(
      step: OnboardingStep.values[value.step.index - 1],
      showWelcome: false,
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