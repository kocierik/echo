import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api/api_service.dart';
import '../services/app/app_controller.dart';
import '../services/app/app_runtime.dart';
import '../services/device/firmware_update.dart';
import '../services/device/device_controller.dart';
import '../services/app/network_policy.dart';
import '../services/onboarding/onboarding_controller.dart';
import '../services/app/session_controller.dart';
import '../theme/app_theme.dart';
import 'device_detail_screen.dart';
import 'device_messages_screen.dart';
import 'settings/about_settings_screen.dart';
import 'settings/automations_settings_screen.dart';
import 'settings/connection_settings_screen.dart';
import 'settings/privacy_settings_screen.dart';
import 'settings/capabilities_screen.dart';
import 'settings/notification_settings_screen.dart';
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

  void _push(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SettingsSection('DEVICE'),
          _DeviceRow(
            firmwareUpdate: AppRuntime.maybeCoordinator?.firmwareUpdate,
            onTap: () => _push(DeviceDetailScreen(
              appController: _appController,
              deviceController: _deviceController,
              resetOnboarding: _clearOnboardingProgress,
              onRequireOnboarding: widget.onRequireOnboarding,
              firmwareUpdate: AppRuntime.maybeCoordinator?.firmwareUpdate,
            )),
          ),
          SettingsRow(
            icon: Icons.wifi_rounded,
            title: 'Connection',
            subtitle: 'Backend server and upload network.',
            onTap: () => _push(ConnectionSettingsScreen(
              networkPolicy: _networkPolicy,
              preferences: _preferences,
              apiServiceFactory: widget.apiServiceFactory,
            )),
          ),
          SettingsRow(
            icon: Icons.shield_outlined,
            title: 'Privacy',
            subtitle: 'Retention, microphone, and transcripts.',
            onTap: () => _push(PrivacySettingsScreen(
              appController: _appController,
              onOpenTranscripts: widget.onOpenTranscripts,
            )),
          ),
          const SettingsSection('ECHO'),
          SettingsRow(
            icon: Icons.auto_awesome_motion_outlined,
            title: 'What Echo can do',
            subtitle: 'Examples to try, by chat and by voice.',
            onTap: () => _push(CapabilitiesScreen(
              onAsk: _appController.requestAsk,
              onOpenVoices: () => _push(const VoiceSettingsScreen()),
            )),
          ),
          SettingsRow(
            icon: Icons.auto_awesome_outlined,
            title: 'Automations',
            subtitle: 'Connected apps and what Echo did with them.',
            onTap: () => _push(AutomationsSettingsScreen(
              activityBuilder: widget.activityBuilder,
              integrationsBuilder: widget.integrationsBuilder,
            )),
          ),
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
            onTap: () => _push(const VoiceSettingsScreen()),
          ),
          SettingsRow(
            icon: Icons.monitor_heart_outlined,
            title: 'Diagnostics',
            subtitle: 'BLE transfer and upload messages.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: widget.diagnosticsBuilder ??
                    (_) => const DeviceMessagesScreen(),
              ),
            ),
          ),
          SettingsRow(
            icon: Icons.info_outline_rounded,
            title: 'About',
            subtitle: 'Appearance, version, licenses, and account.',
            onTap: () => _push(AboutSettingsScreen(
              appController: _appController,
              sessionController: _sessionController,
              onLoggedOut: widget.onRequireOnboarding ?? () {},
            )),
          ),
        ],
      ),
    );
  }
}

/// The Device row, which also says when a new firmware is ready.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.firmwareUpdate, required this.onTap});

  final FirmwareUpdateController? firmwareUpdate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    Widget row(FirmwareUpdateState? update) => SettingsRow(
          icon: Icons.watch_outlined,
          title: 'Device',
          subtitle: update?.phase == FirmwareUpdatePhase.available
              ? 'Firmware ${update!.release!.version} is ready to install.'
              : 'Status, storage, software, and pairing.',
          onTap: onTap,
        );
    final controller = firmwareUpdate;
    if (controller == null) return row(null);
    return ValueListenableBuilder<FirmwareUpdateState>(
      valueListenable: controller,
      builder: (context, update, _) => row(update),
    );
  }
}
