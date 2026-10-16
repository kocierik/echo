import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api/api_service.dart';
import '../services/app/app_controller.dart';
import '../services/app/app_runtime.dart';
import '../services/device/firmware_update.dart';
import '../services/device/device_controller.dart';
import '../services/device/phone_words.dart';
import '../services/app/network_policy.dart';
import '../services/onboarding/onboarding_controller.dart';
import '../services/app/session_controller.dart';
import '../services/app/spoken_language.dart';
import '../models/app_view_state.dart';
import '../theme/app_theme.dart';
import '../widgets/device_instrument.dart';
import '../widgets/screen_header.dart';
import 'device_detail_screen.dart';
import 'device_messages_screen.dart';
import 'settings/about_settings_screen.dart';
import 'action_log_screen.dart';
import 'integrations_screen.dart';
import 'settings/appearance_settings_screen.dart';
import 'settings/phone_apps_screen.dart';
import 'settings/connection_settings_screen.dart';
import 'settings/devices_screen.dart';
import 'settings/privacy_settings_screen.dart';
import 'settings/capabilities_screen.dart';
import 'settings/notification_settings_screen.dart';
import 'settings/language_settings_screen.dart';
import 'settings/voice_settings_screen.dart';
import 'settings/settings_components.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    this.deviceController,
    this.appController,
    this.sessionController,
    this.networkPolicy,
    this.preferences,
    this.onRequireOnboarding,
    this.onOpenTranscripts,
    this.apiServiceFactory,
    this.diagnosticsBuilder,
    this.activityBuilder,
    this.integrationsBuilder,
    this.devicesBuilder,
    super.key,
  });

  final DeviceController? deviceController;
  final AppController? appController;
  final SessionController? sessionController;
  final NetworkPolicy? networkPolicy;
  final SharedPreferences? preferences;
  final VoidCallback? onRequireOnboarding;
  final VoidCallback? onOpenTranscripts;
  final ApiService Function()? apiServiceFactory;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? activityBuilder;
  final WidgetBuilder? integrationsBuilder;
  final WidgetBuilder? devicesBuilder;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final DeviceController _deviceController;
  late final AppController _appController;
  late final SessionController _sessionController;
  late final NetworkPolicy _networkPolicy;
  late final SharedPreferences _preferences;

  @override
  void initState() {
    super.initState();
    final fullyInjected = widget.deviceController != null &&
        widget.appController != null &&
        widget.sessionController != null &&
        widget.networkPolicy != null &&
        widget.preferences != null;
    final coordinator = fullyInjected ? null : AppRuntime.coordinator;
    _deviceController =
        widget.deviceController ?? coordinator!.deviceController;
    _appController = widget.appController ?? coordinator!.appController;
    _sessionController =
        widget.sessionController ?? coordinator!.sessionController;
    _networkPolicy = widget.networkPolicy ?? coordinator!.networkPolicy;
    _preferences = widget.preferences ?? coordinator!.preferences;
  }

  Future<void> _clearOnboardingProgress() async {
    final removed = await Future.wait([
      _preferences.remove(OnboardingController.completedKey),
      _preferences.remove(OnboardingController.highestStepKey),
      _preferences.remove('echo_onboarding_complete'),
    ]);
    if (removed.any((success) => !success)) {
      throw StateError('Could not clear onboarding progress');
    }
  }

  Future<void> _push(Widget page) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  }

  bool _muteBusy = false;

  /// Mute Echo or let it listen again; the panel changes once Echo confirms.
  Future<void> _setMuted(bool muted) async {
    setState(() => _muteBusy = true);
    try {
      await _deviceController.setMuted(muted);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Echo could not update the microphone.')));
      }
    } finally {
      if (mounted) setState(() => _muteBusy = false);
    }
  }

  void _openDevice() => _push(DeviceDetailScreen(
        appController: _appController,
        deviceController: _deviceController,
        resetOnboarding: _clearOnboardingProgress,
        onRequireOnboarding: widget.onRequireOnboarding,
        firmwareUpdate: AppRuntime.maybeCoordinator?.firmwareUpdate,
      ));

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final phoneActions = AppRuntime.maybeCoordinator?.phoneActions;
    final firmwareUpdate = AppRuntime.maybeCoordinator?.firmwareUpdate;
    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            ScreenHeader(
              title: 'Settings',
              actions: [
                if (Navigator.canPop(context))
                  TextButton(
                    key: const Key('settings-done'),
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      backgroundColor: palette.surface,
                      foregroundColor: palette.text,
                      minimumSize: const Size(44, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      shape: const StadiumBorder(),
                    ),
                    child: const Text('Done'),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ValueListenableBuilder(
                valueListenable: _appController,
                builder: (context, state, _) => _firmwareAware(
                  firmwareUpdate,
                  (update) => DeviceInstrumentPanel(
                    status: state.device,
                    busy: _muteBusy,
                    onMute: (muted) => _setMuted(muted),
                    onReconnect: () => _deviceController.reconnect(),
                    onPair: widget.onRequireOnboarding,
                    onDetails: _openDevice,
                    firmwareLine: update?.phase == FirmwareUpdatePhase.available
                        ? 'Firmware ${update!.release!.version} is ready to install, in Device details.'
                        : state.device.firmwareVersion == null
                            ? null
                            : 'Firmware ${state.device.firmwareVersion}',
                  ),
                ),
              ),
            ),
            SettingsGroup(children: [
              SettingsRow(
                icon: Icons.extension_outlined,
                title: 'Apps',
                subtitle: 'Connect the apps Echo can act in.',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: widget.integrationsBuilder ?? (_) => const IntegrationsScreen(),
                  ),
                ),
              ),
              if (phoneActions != null)
                SettingsRow(
                  icon: PhoneWords.isIPhone
                      ? Icons.phone_iphone_rounded
                      : Icons.phone_android_rounded,
                  title: PhoneWords.onThisPhone,
                  subtitle: PhoneWords.isIPhone
                      ? 'Reminders and Calendar, for Echo to use.'
                      : 'The calendar, for Echo to use.',
                  onTap: () => _push(PhoneAppsScreen(phoneActions: phoneActions)),
                ),
              SettingsRow(
                icon: Icons.history_rounded,
                title: 'Activity',
                subtitle: 'What Echo did in your apps.',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: widget.activityBuilder ?? (_) => const ActionLogScreen(),
                  ),
                ),
              ),
            ]),
            SettingsGroup(children: [
              SettingsRow(
                icon: Icons.notifications_none_rounded,
                title: 'Notifications',
                subtitle: 'Before meetings and for promises, only when needed.',
                onTap: () => _push(NotificationSettingsScreen(
                  preferences: _preferences,
                  onChanged: () {
                    final coordinator = AppRuntime.maybeCoordinator;
                    coordinator?.notificationScheduler.refresh(force: true);
                    coordinator?.liveActivity.refresh();
                  },
                )),
              ),
              SettingsRow(
                icon: Icons.record_voice_over_outlined,
                title: 'Voices',
                subtitle: 'Your voice, and the people Echo recognises.',
                onTap: () => _push(VoiceSettingsScreen(
                  language: _preferences.getString(SpokenLanguageStore.key),
                )),
              ),
              SettingsRow(
                key: const Key('settings-language'),
                icon: Icons.translate_rounded,
                title: 'Language',
                subtitle: spokenLanguages[_preferences.getString(SpokenLanguageStore.key)] ??
                    'The language you speak.',
                onTap: () async {
                  await _push(LanguageSettingsScreen(
                    store: SpokenLanguageStore(
                      api: (widget.apiServiceFactory ?? ApiService.new)(),
                      preferences: _preferences,
                    ),
                  ));
                  if (mounted) setState(() {});
                },
              ),
              ValueListenableBuilder(
                valueListenable: _appController,
                builder: (context, state, _) => SettingsRow(
                  icon: Icons.contrast_rounded,
                  title: 'Appearance',
                  subtitle: switch (state.themePreference) {
                    ThemePreference.system => 'System: light by day, dark at night',
                    ThemePreference.light => 'Light',
                    ThemePreference.dark => 'Dark',
                  },
                  onTap: () => _push(AppearanceSettingsScreen(appController: _appController)),
                ),
              ),
              SettingsRow(
                icon: Icons.shield_outlined,
                title: 'Privacy',
                subtitle: 'What Echo keeps, and for how long.',
                onTap: () => _push(PrivacySettingsScreen(
                  appController: _appController,
                  onOpenTranscripts: widget.onOpenTranscripts,
                )),
              ),
            ]),
            SettingsGroup(children: [
              SettingsRow(
                icon: Icons.auto_awesome_outlined,
                title: 'What Echo can do',
                subtitle: 'Examples to try, by chat and by voice.',
                onTap: () => _push(CapabilitiesScreen(
                  onAsk: _appController.requestAsk,
                  onOpenVoices: () => _push(const VoiceSettingsScreen()),
                )),
              ),
              SettingsRow(
                icon: Icons.dns_outlined,
                title: 'Server connection',
                subtitle: 'The Echo server, and uploads over mobile data.',
                onTap: () => _push(ConnectionSettingsScreen(
                  networkPolicy: _networkPolicy,
                  preferences: _preferences,
                  apiServiceFactory: widget.apiServiceFactory,
                )),
              ),
              SettingsRow(
                icon: Icons.monitor_heart_outlined,
                title: 'Diagnostics',
                subtitle: 'Bluetooth transfers and upload messages.',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: widget.diagnosticsBuilder ?? (_) => const DeviceMessagesScreen(),
                  ),
                ),
              ),
              SettingsRow(
                icon: Icons.devices_rounded,
                title: 'Devices',
                subtitle: 'Phones signed in to your account.',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: widget.devicesBuilder ?? (_) => const DevicesScreen(),
                  ),
                ),
              ),
              SettingsRow(
                icon: Icons.info_outline_rounded,
                title: 'About',
                subtitle: 'Version, licenses and your account.',
                onTap: () => _push(AboutSettingsScreen(
                  appController: _appController,
                  sessionController: _sessionController,
                  onLoggedOut: widget.onRequireOnboarding ?? () {},
                )),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Builds with the firmware update's state, or without one (tests, no server).
Widget _firmwareAware(
  FirmwareUpdateController? controller,
  Widget Function(FirmwareUpdateState? update) builder,
) {
  if (controller == null) return builder(null);
  return ValueListenableBuilder<FirmwareUpdateState>(
    valueListenable: controller,
    builder: (context, update, _) => builder(update),
  );
}
