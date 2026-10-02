import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/app_view_state.dart';
import '../models/device_status.dart';
import '../models/session_state.dart';
import 'app_preferences.dart';

export 'app_preferences.dart';

final class AppController extends ValueNotifier<AppViewState> {
  AppController({
    required DeviceStatus initialDevice,
    required Stream<DeviceStatus> deviceStates,
    required SessionState initialSession,
    required Stream<SessionState> sessionStates,
    required AppPreferences preferences,
  })  : _deviceStates = deviceStates,
        _sessionStates = sessionStates,
        _preferences = preferences,
        super(AppViewState(
          session: initialSession,
          device: initialDevice,
        ));

  static const themePreferenceKey = 'echo_theme_mode';
  static const selectedTabKey = 'echo_selected_tab';

  final Stream<DeviceStatus> _deviceStates;
  final Stream<SessionState> _sessionStates;
  final AppPreferences _preferences;

  StreamSubscription<DeviceStatus>? _deviceSubscription;
  StreamSubscription<SessionState>? _sessionSubscription;
  Future<void>? _initialization;
  bool _disposed = false;

  ThemeMode get themeMode {
    return switch (value.themePreference) {
      ThemePreference.system => ThemeMode.system,
      ThemePreference.light => ThemeMode.light,
      ThemePreference.dark => ThemeMode.dark,
    };
  }

  Future<void> initialize() {
    if (_disposed) throw StateError('AppController is disposed');
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    final themePreference = _readThemePreference(
      _preferences.getString(themePreferenceKey),
    );
    final selectedTab = _readSelectedTab(
      _preferences.getInt(selectedTabKey),
    );
    if (_disposed) return;

    value = value.copyWith(
      themePreference: themePreference,
      selectedTab: selectedTab,
    );
    _deviceSubscription = _deviceStates.listen(_onDeviceState);
    _sessionSubscription = _sessionStates.listen(_onSessionState);
  }

  Future<void> setTheme(ThemePreference preference) async {
    _ensureActive();
    if (value.themePreference != preference) {
      value = value.copyWith(themePreference: preference);
    }
    await _preferences.setString(themePreferenceKey, preference.name);
  }

  Future<void> setSelectedTab(int selectedTab) async {
    _ensureActive();
    if (selectedTab < 0 || selectedTab > 2) {
      throw RangeError.range(selectedTab, 0, 2, 'selectedTab');
    }
    if (value.selectedTab != selectedTab) {
      value = value.copyWith(selectedTab: selectedTab);
    }
    await _preferences.setInt(selectedTabKey, selectedTab);
  }

  void _onDeviceState(DeviceStatus device) {
    if (_disposed || value.device == device) return;
    value = value.copyWith(device: device);
  }

  void _onSessionState(SessionState session) {
    if (_disposed || value.session == session) return;
    value = value.copyWith(session: session);
  }

  ThemePreference _readThemePreference(String? storedValue) {
    return ThemePreference.values.firstWhere(
      (preference) => preference.name == storedValue,
      orElse: () => ThemePreference.system,
    );
  }

  int _readSelectedTab(int? storedValue) {
    if (storedValue == null || storedValue < 0 || storedValue > 2) return 0;
    return storedValue;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('AppController is disposed');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_deviceSubscription?.cancel());
    unawaited(_sessionSubscription?.cancel());
    super.dispose();
  }
}