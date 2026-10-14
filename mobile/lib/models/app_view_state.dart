import 'device_status.dart';
import 'session_state.dart';

enum ThemePreference { system, light, dark }

final class AppViewState {
  const AppViewState({
    required this.session,
    required this.device,
    this.themePreference = ThemePreference.system,
    this.selectedTab = 0,
  }) : assert(selectedTab >= 0 && selectedTab < tabCount);

  /// Today, Memories, Tasks, Ask.
  static const tabCount = 4;

  final SessionState session;
  final DeviceStatus device;
  final ThemePreference themePreference;
  final int selectedTab;

  AppViewState copyWith({
    SessionState? session,
    DeviceStatus? device,
    ThemePreference? themePreference,
    int? selectedTab,
  }) {
    return AppViewState(
      session: session ?? this.session,
      device: device ?? this.device,
      themePreference: themePreference ?? this.themePreference,
      selectedTab: selectedTab ?? this.selectedTab,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AppViewState &&
            session == other.session &&
            device == other.device &&
            themePreference == other.themePreference &&
            selectedTab == other.selectedTab;
  }

  @override
  int get hashCode {
    return Object.hash(session, device, themePreference, selectedTab);
  }
}