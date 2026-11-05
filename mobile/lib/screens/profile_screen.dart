import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_view_state.dart';
import '../models/device_status.dart';
import '../models/plan.dart';
import '../models/whatsapp.dart';
import '../services/api/api_service.dart';
import '../services/app/app_controller.dart';
import '../services/app/app_runtime.dart';
import '../services/app/network_policy.dart';
import '../services/app/session_controller.dart';
import '../services/app/spoken_answers_store.dart';
import '../services/app/spoken_language.dart';
import '../services/device/device_controller.dart';
import '../services/device/phone_words.dart';
import '../services/phone/places_visited.dart';
import '../theme/app_theme.dart';
import '../widgets/person_avatar.dart';
import '../widgets/screen_header.dart';
import 'action_log_screen.dart';
import 'device_messages_screen.dart';
import 'echo_device_screen.dart';
import 'integrations_screen.dart';
import 'settings/about_settings_screen.dart';
import 'settings/appearance_settings_screen.dart';
import 'settings/assistants_screen.dart';
import 'settings/capabilities_screen.dart';
import 'settings/connection_settings_screen.dart';
import 'settings/devices_screen.dart';
import 'settings/example_data_screen.dart';
import 'settings/health_screen.dart';
import 'settings/instructions_screen.dart';
import 'settings/language_settings_screen.dart';
import 'settings/logout_row.dart';
import 'settings/memory_screen.dart';
import 'settings/notification_settings_screen.dart';
import 'settings/phone_apps_screen.dart';
import 'settings/places_visited_screen.dart';
import 'settings/plan_screen.dart';
import 'settings/privacy_settings_screen.dart';
import 'settings/routines_screen.dart';
import 'settings/settings_components.dart';
import 'settings/spoken_answers_screen.dart';
import 'settings/voice_settings_screen.dart';
import 'settings/whatsapp_screen.dart';

/// Profile, the third tab: the account, Echo, the plan, then every setting in groups:
/// what Echo does, what is about the user, what Echo can do, and one row for the rest.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    this.deviceController,
    this.appController,
    this.sessionController,
    this.networkPolicy,
    this.preferences,
    this.onRequireOnboarding,
    this.onOpenTranscripts,
    this.onOpenDevice,
    this.apiServiceFactory,
    this.diagnosticsBuilder,
    this.activityBuilder,
    this.integrationsBuilder,
    this.devicesBuilder,
    this.placesVisited,
    this.spokenAnswers,
    this.onTrySpeaking,
    super.key,
  });

  final DeviceController? deviceController;
  final AppController? appController;
  final SessionController? sessionController;
  final NetworkPolicy? networkPolicy;
  final SharedPreferences? preferences;
  final VoidCallback? onRequireOnboarding;
  final VoidCallback? onOpenTranscripts;

  /// The Echo card; the Echo screen by default.
  final VoidCallback? onOpenDevice;
  final ApiService Function()? apiServiceFactory;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? activityBuilder;
  final WidgetBuilder? integrationsBuilder;
  final WidgetBuilder? devicesBuilder;

  /// Places visited; the app's own by default (no row without one).
  final PlacesVisitedService? placesVisited;

  /// Spoken answers and its "Try it"; the app's own by default (no row without them).
  final SpokenAnswersStore? spokenAnswers;
  final Future<void> Function()? onTrySpeaking;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final DeviceController _deviceController;
  late final AppController _appController;
  late final SessionController _sessionController;
  late final NetworkPolicy _networkPolicy;
  late final SharedPreferences _preferences;
  late final ApiService _api;

  AccountInfo? _account;

  /// The connected apps, by name ("Gmail, Google Calendar").
  String? _apps;

  PlanInfo? _plan;

  /// Null until the server says; a row only where it has WhatsApp.
  WhatsAppStatus? _whatsapp;

  @override
  void initState() {
    super.initState();
    final fullyInjected = widget.deviceController != null &&
        widget.appController != null &&
        widget.sessionController != null &&
        widget.networkPolicy != null &&
        widget.preferences != null;
    final coordinator = fullyInjected ? null : AppRuntime.coordinator;
    _deviceController = widget.deviceController ?? coordinator!.deviceController;
    _appController = widget.appController ?? coordinator!.appController;
    _sessionController = widget.sessionController ?? coordinator!.sessionController;
    _networkPolicy = widget.networkPolicy ?? coordinator!.networkPolicy;
    _preferences = widget.preferences ?? coordinator!.preferences;
    _api = (widget.apiServiceFactory ?? ApiService.new)();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (widget.apiServiceFactory == null) _api.dispose();
    super.dispose();
  }

  /// The account and the connected apps; a failure leaves them out.
  Future<void> _load() async {
    try {
      final account = await _api.me();
      if (mounted) setState(() => _account = account);
    } catch (_) {}
    try {
      final connected = (await _api.getToolkits()).where((t) => t.connected).toList();
      if (mounted) {
        setState(() => _apps = connected.isEmpty ? null : connected.map((t) => t.name).join(', '));
      }
    } catch (_) {}
    await _loadPlan();
    await _loadWhatsApp();
  }

  Future<void> _loadWhatsApp() async {
    try {
      final whatsapp = await _api.getWhatsApp();
      if (mounted) setState(() => _whatsapp = whatsapp);
    } catch (_) {}
  }

  /// The plan and this month's speech; a server that cannot say shows no row.
  Future<void> _loadPlan() async {
    try {
      final plan = await _api.getPlan();
      if (mounted) setState(() => _plan = plan);
    } catch (_) {}
  }

  Future<void> _push(Widget page) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  }

  void _openDevice() {
    final open = widget.onOpenDevice;
    if (open != null) {
      open();
      return;
    }
    unawaited(openEchoDevice(
      context,
      appController: _appController,
      deviceController: _deviceController,
      preferences: _preferences,
      onRequireOnboarding: widget.onRequireOnboarding,
    ));
  }

  void _openMore() => _push(_MoreScreen(
        networkPolicy: _networkPolicy,
        preferences: _preferences,
        apiServiceFactory: widget.apiServiceFactory,
        diagnosticsBuilder: widget.diagnosticsBuilder,
        devicesBuilder: widget.devicesBuilder,
        appController: _appController,
        sessionController: _sessionController,
        onLoggedOut: widget.onRequireOnboarding ?? () {},
      ));

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final phoneActions = AppRuntime.maybeCoordinator?.phoneActions;
    final places = widget.placesVisited ?? AppRuntime.maybeCoordinator?.placesVisited;
    final language = spokenLanguages[_preferences.getString(SpokenLanguageStore.key) ??
        _account?.language];
    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        bottom: false,
        child: ListView(
          key: const Key('profile'),
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            ScreenHeader(
              title: 'Profile',
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
            _AccountCard(account: _account, language: language),
            ValueListenableBuilder<AppViewState>(
              valueListenable: _appController,
              builder: (context, state, _) =>
                  _EchoCard(status: state.device, onTap: _openDevice),
            ),
            if (_plan case final plan?) ...[
              const SizedBox(height: 8),
              SettingsGroup(children: [
                SettingsRow(
                  key: const Key('profile-plan'),
                  icon: Icons.data_usage_rounded,
                  title: 'Plan',
                  value: plan.name,
                  subtitle: plan.usageLine,
                  onTap: () async {
                    await _push(PlanScreen(api: _api, initial: plan));
                    if (mounted) unawaited(_loadPlan());
                  },
                ),
              ]),
            ],
            const SettingsSection('ECHO DOES'),
            SettingsGroup(children: [
              SettingsRow(
                icon: Icons.extension_outlined,
                title: 'Apps',
                subtitle: _apps == null ? 'Connect the apps Echo can act in.' : null,
                value: _apps,
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: widget.integrationsBuilder ?? (_) => const IntegrationsScreen(),
                    ),
                  );
                  if (mounted) unawaited(_load());
                },
              ),
              SettingsRow(
                key: const Key('profile-routines'),
                icon: Icons.schedule_rounded,
                title: 'Routines',
                subtitle: 'What Echo does on its own, and when.',
                onTap: () => _push(RoutinesScreen(
                  onOpenResults: (id) => _appController.requestOpenRoutines(routineId: id),
                  onOpenThread: _appController.requestOpenThread,
                )),
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
                icon: Icons.history_rounded,
                title: 'Activity',
                subtitle: 'What Echo did in your apps.',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: widget.activityBuilder ?? (_) => const ActionLogScreen(),
                  ),
                ),
              ),
            ]),
            const SettingsSection('YOU'),
            SettingsGroup(children: [
              SettingsRow(
                key: const Key('profile-instructions'),
                icon: Icons.tune_rounded,
                title: 'Instructions',
                subtitle: _account?.instructions?.split('\n').first ??
                    'How Echo talks to you.',
                onTap: () async {
                  final account = await Navigator.push<AccountInfo>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => InstructionsScreen(
                        api: _api,
                        initial: _account?.instructions,
                      ),
                    ),
                  );
                  if (account != null && mounted) setState(() => _account = account);
                },
              ),
              SettingsRow(
                key: const Key('profile-memory'),
                icon: Icons.psychology_outlined,
                title: 'Memory',
                subtitle: 'What Echo knows about you, and your documents.',
                onTap: () => _push(MemoryScreen(facts: _api, documents: _api)),
              ),
              SettingsRow(
                key: const Key('profile-assistants'),
                icon: Icons.smart_toy_outlined,
                title: 'Assistants',
                subtitle: 'Echo for work, diet, sleep, or what you choose.',
                onTap: () => _push(AssistantsScreen(api: _api, documents: _api)),
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
                value: language,
                subtitle: language == null ? 'The language you speak.' : null,
                onTap: () async {
                  await _push(LanguageSettingsScreen(
                    store: SpokenLanguageStore(api: _api, preferences: _preferences),
                  ));
                  if (mounted) setState(() {});
                },
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
              if (places != null)
                ValueListenableBuilder<bool>(
                  valueListenable: places.on,
                  builder: (context, on, _) => SettingsRow(
                    key: const Key('profile-places'),
                    icon: Icons.place_outlined,
                    title: 'Places visited',
                    subtitle: on
                        ? 'On: where you stayed, kept for 90 days.'
                        : 'Off. Echo can note where you stay.',
                    onTap: () => _push(PlacesVisitedScreen(places: places, api: _api)),
                  ),
                ),
              SettingsRow(
                key: const Key('profile-health'),
                icon: Icons.favorite_border_rounded,
                title: 'Health',
                subtitle: 'Sleep, steps and workouts, from the Health app.',
                onTap: () => _push(HealthScreen(api: _api)),
              ),
              if (_whatsapp case final whatsapp? when whatsapp.available)
                SettingsRow(
                  key: const Key('profile-whatsapp'),
                  icon: Icons.chat_outlined,
                  title: 'WhatsApp',
                  subtitle: whatsAppText(whatsapp),
                  onTap: () async {
                    await _push(WhatsAppScreen(api: _api));
                    await _loadWhatsApp();
                  },
                ),
              if (widget.spokenAnswers ?? AppRuntime.maybeCoordinator?.spokenAnswers
                  case final spoken?)
                ValueListenableBuilder<SpokenAnswers>(
                  valueListenable: spoken,
                  builder: (context, choice, _) => SettingsRow(
                    key: const Key('profile-spoken-answers'),
                    icon: Icons.record_voice_over_outlined,
                    title: 'Spoken answers',
                    subtitle: spokenAnswersText(choice),
                    onTap: () => _push(SpokenAnswersScreen(
                      store: spoken,
                      onTry: widget.onTrySpeaking ??
                          AppRuntime.maybeCoordinator?.answerSpeaker.sample ??
                          () async {},
                      voices: AppRuntime.maybeCoordinator?.phoneVoice,
                      voiceStore: AppRuntime.maybeCoordinator?.spokenVoice,
                      language: _preferences.getString(SpokenLanguageStore.key) ?? 'en',
                    )),
                  ),
                ),
              ValueListenableBuilder<AppViewState>(
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
            ]),
            const SizedBox(height: 4),
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
                key: const Key('profile-example-data'),
                icon: Icons.auto_awesome_motion_outlined,
                title: 'Example data',
                subtitle: 'A few example days, to see Echo filled in.',
                onTap: () => _push(ExampleDataScreen(api: _api)),
              ),
              SettingsRow(
                key: const Key('profile-more'),
                icon: Icons.tune_rounded,
                title: 'Devices, server, diagnostics, about',
                onTap: _openMore,
              ),
            ]),
            const SizedBox(height: 4),
            SettingsGroup(children: [
              LogoutRow(
                key: const Key('profile-logout'),
                sessionController: _sessionController,
                onLoggedOut: widget.onRequireOnboarding ?? () {},
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// The account: initial, email and spoken language.
final class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.language});

  final AccountInfo? account;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final email = account?.email;
    return Padding(
      key: const Key('profile-account'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppTheme.panelRadius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              PersonAvatar(
                initials: email == null || email.isEmpty
                    ? '?'
                    : email.characters.first.toUpperCase(),
                size: 52,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      email ?? 'Your account',
                      style: textTheme.titleMedium,
                    ),
                    if (language != null) ...[
                      const SizedBox(height: 2),
                      Text(language!, style: textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Echo in one line: its state, battery and firmware; a tap opens the Echo screen.
final class _EchoCard extends StatelessWidget {
  const _EchoCard({required this.status, required this.onTap});

  final DeviceStatus status;
  final VoidCallback onTap;

  static String stateLabel(DeviceConnectionState state) => switch (state) {
        DeviceConnectionState.listening => 'Listening',
        DeviceConnectionState.muted => 'Muted',
        DeviceConnectionState.scanning ||
        DeviceConnectionState.connecting ||
        DeviceConnectionState.bonding ||
        DeviceConnectionState.reconnecting =>
          'Connecting',
        DeviceConnectionState.bluetoothOff => 'Bluetooth is off',
        DeviceConnectionState.offline || DeviceConnectionState.error => 'Offline',
        DeviceConnectionState.unpaired => 'Not paired',
      };

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final line = [
      stateLabel(status.connectionState),
      if (status.batteryPercent case final battery?) 'battery $battery%',
      if (status.firmwareVersion case final firmware?) 'firmware $firmware',
    ].join(' · ');
    final radius = BorderRadius.circular(AppTheme.panelRadius);
    final live = status.connectionState == DeviceConnectionState.listening;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Material(
        color: palette.surface,
        borderRadius: radius,
        child: InkWell(
          key: const Key('profile-device'),
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.topCenter,
                  padding: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(color: palette.chromeRaised, shape: BoxShape.circle),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: live ? palette.live : null,
                      border: live ? null : Border.all(color: palette.onChromeMuted, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Echo', style: textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(line, style: textTheme.bodySmall),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: palette.text2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// Devices, server connection, diagnostics and About: rarely needed, one row down.
final class _MoreScreen extends StatelessWidget {
  const _MoreScreen({
    required this.networkPolicy,
    required this.preferences,
    required this.appController,
    required this.sessionController,
    required this.onLoggedOut,
    this.apiServiceFactory,
    this.diagnosticsBuilder,
    this.devicesBuilder,
  });

  final NetworkPolicy networkPolicy;
  final SharedPreferences preferences;
  final AppController appController;
  final SessionController sessionController;
  final VoidCallback onLoggedOut;
  final ApiService Function()? apiServiceFactory;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? devicesBuilder;

  @override
  Widget build(BuildContext context) {
    void push(WidgetBuilder builder) =>
        Navigator.push(context, MaterialPageRoute<void>(builder: builder));
    return SettingsPageScaffold(
      title: 'More',
      children: [
        SettingsRow(
          icon: Icons.devices_rounded,
          title: 'Devices',
          subtitle: 'Phones, and assistants that read your memory.',
          onTap: () => push(devicesBuilder ?? (_) => const DevicesScreen()),
        ),
        SettingsRow(
          icon: Icons.dns_outlined,
          title: 'Server connection',
          subtitle: 'The Echo server, and uploads over mobile data.',
          onTap: () => push((_) => ConnectionSettingsScreen(
                networkPolicy: networkPolicy,
                preferences: preferences,
                apiServiceFactory: apiServiceFactory,
              )),
        ),
        SettingsRow(
          icon: Icons.monitor_heart_outlined,
          title: 'Diagnostics',
          subtitle: 'Bluetooth transfers and upload messages.',
          onTap: () => push(diagnosticsBuilder ?? (_) => const DeviceMessagesScreen()),
        ),
        SettingsRow(
          icon: Icons.info_outline_rounded,
          title: 'About',
          subtitle: 'Version, licenses and your account.',
          onTap: () => push((_) => AboutSettingsScreen(
                appController: appController,
                sessionController: sessionController,
                onLoggedOut: onLoggedOut,
              )),
        ),
      ],
    );
  }
}
