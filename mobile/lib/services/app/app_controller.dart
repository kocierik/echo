import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/app_view_state.dart';
import '../../models/device_status.dart';
import '../../models/session_state.dart';
import 'app_preferences.dart';
import 'notification_service.dart';

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
  // v3: Today, Ask, Memories (Tasks became a page of Today); an older index
  // would open the wrong tab
  static const selectedTabKey = 'echo_selected_tab_v3';
  static const todayTab = 0;
  static const askTab = 1;
  static const memoriesTab = 2;
  static const tabCount = AppViewState.tabCount;

  /// A chat session the Ask tab should open (e.g. from a notification tap).
  /// The chat screen loads it and sets it back to null.
  final ValueNotifier<String?> pendingChatSessionId = ValueNotifier(null);

  /// A question the Ask tab should send in a new chat ("Ask about Marco").
  /// The chat screen sends it and sets it back to null.
  final ValueNotifier<String?> pendingChatQuestion = ValueNotifier(null);

  /// A person whose page should open (a briefing notification); set back to null
  /// once opened.
  final ValueNotifier<String?> pendingPersonId = ValueNotifier(null);

  /// Counts the requests to open the Tasks page (a promises notification); the
  /// shell opens it on each change.
  final ValueNotifier<int> openTasksRequests = ValueNotifier(0);

  /// True while the Ask button is held: Ask dictates into its question.
  final ValueNotifier<bool> askDictation = ValueNotifier(false);

  static const personPayloadPrefix = 'person:';

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
    if (selectedTab < 0 || selectedTab >= tabCount) {
      throw RangeError.range(selectedTab, 0, tabCount - 1, 'selectedTab');
    }
    if (value.selectedTab != selectedTab) {
      value = value.copyWith(selectedTab: selectedTab);
    }
    await _preferences.setInt(selectedTabKey, selectedTab);
  }

  /// Selects the Ask tab and asks the chat screen to open session [id].
  void requestOpenSession(String id) {
    if (_disposed || id.isEmpty) return;
    pendingChatSessionId.value = id;
    unawaited(setSelectedTab(askTab));
  }

  /// Selects the Ask tab and asks it to send [question] in a new chat.
  void requestAsk(String question) {
    final text = question.trim();
    if (_disposed || text.isEmpty) return;
    pendingChatQuestion.value = text;
    unawaited(setSelectedTab(askTab));
  }

  /// Selects Today and opens its Tasks page.
  void requestOpenTasks() {
    if (_disposed) return;
    unawaited(setSelectedTab(todayTab));
    openTasksRequests.value++;
  }

  /// The Ask button: held, Ask opens and dictates until it is let go.
  void setAskDictation(bool holding) {
    if (_disposed) return;
    if (holding) unawaited(setSelectedTab(askTab));
    askDictation.value = holding;
  }

  /// Routes a tapped notification: "voice:<sessionId>" opens that session in
  /// Ask ("voice:" alone only selects Ask), "person:<id>" that person's page,
  /// "tasks" the Tasks page, "today" Today; other payloads are ignored.
  void handleNotificationPayload(String payload) {
    if (_disposed) return;
    if (payload == 'tasks') {
      requestOpenTasks();
      return;
    }
    if (payload == 'today') {
      unawaited(setSelectedTab(todayTab));
      return;
    }
    if (payload.startsWith(personPayloadPrefix)) {
      final id = payload.substring(personPayloadPrefix.length).trim();
      if (id.isNotEmpty) pendingPersonId.value = id;
      return;
    }
    const prefix = NotificationService.voicePayloadPrefix;
    if (!payload.startsWith(prefix)) return;
    final id = payload.substring(prefix.length).trim();
    if (id.isEmpty) {
      unawaited(setSelectedTab(askTab));
    } else {
      requestOpenSession(id);
    }
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
    if (storedValue == null || storedValue < 0 || storedValue >= tabCount) {
      return todayTab;
    }
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
    pendingChatSessionId.dispose();
    pendingPersonId.dispose();
    pendingChatQuestion.dispose();
    openTasksRequests.dispose();
    askDictation.dispose();
    super.dispose();
  }
}