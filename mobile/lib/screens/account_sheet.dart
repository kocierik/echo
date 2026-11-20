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
import '../services/app/spoken_voice_store.dart';
import '../services/device/device_controller.dart';
import '../services/google_identity.dart';
import '../services/device/phone_words.dart';
import '../services/phone/phone_actions.dart';
import '../services/phone/places_visited.dart';
import '../theme/app_theme.dart';
import 'action_log_screen.dart';
import 'device_messages_screen.dart';
import 'echo_device_screen.dart';
import 'integrations_screen.dart';
import 'settings/about_settings_screen.dart';
import 'settings/appearance_settings_screen.dart';
import 'settings/assistants_screen.dart';
import 'settings/capabilities_screen.dart';
import 'settings/connection_settings_screen.dart';
import 'settings/delete_account_row.dart';
import 'settings/devices_screen.dart';
import 'settings/example_data_screen.dart';
import 'settings/health_screen.dart';
import 'settings/language_settings_screen.dart';
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

/// The account sheet, over the tabs: the pendant, then what Echo does, what is about the
/// user, and every setting. A row closes the sheet and opens its screen on the page the
/// sheet came from, under the tab bar.
Future<void> showAccountSheet(
  BuildContext context, {
  required AppController appController,
  DeviceController? deviceController,
  SessionController? sessionController,
  NetworkPolicy? networkPolicy,
  SharedPreferences? preferences,
  VoidCallback? onRequireOnboarding,
  VoidCallback? onOpenTranscripts,
  ApiService Function()? apiServiceFactory,
  WidgetBuilder? diagnosticsBuilder,
  WidgetBuilder? activityBuilder,
  WidgetBuilder? integrationsBuilder,
  WidgetBuilder? devicesBuilder,
  PlacesVisitedService? placesVisited,
  SpokenAnswersStore? spokenAnswers,
  SpokenVoiceStore? spokenVoice,
  Future<void> Function()? onTrySpeaking,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: EchoPalette.of(context).background,
    constraints:
        BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
    builder: (_) => AccountSheet(
      pageContext: context,
      appController: appController,
      deviceController: deviceController,
      sessionController: sessionController,
      networkPolicy: networkPolicy,
      preferences: preferences,
      onRequireOnboarding: onRequireOnboarding,
      onOpenTranscripts: onOpenTranscripts,
      apiServiceFactory: apiServiceFactory,
      diagnosticsBuilder: diagnosticsBuilder,
      activityBuilder: activityBuilder,
      integrationsBuilder: integrationsBuilder,
      devicesBuilder: devicesBuilder,
      placesVisited: placesVisited,
      spokenAnswers: spokenAnswers,
      spokenVoice: spokenVoice,
      onTrySpeaking: onTrySpeaking,
    ),
  );
}

class AccountSheet extends StatefulWidget {
  const AccountSheet({
    required this.pageContext,
    required this.appController,
    this.deviceController,
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
    this.placesVisited,
    this.spokenAnswers,
    this.spokenVoice,
    this.onTrySpeaking,
    super.key,
  });

  /// The page the sheet opened from: its navigator takes the screens the rows open.
  final BuildContext pageContext;
  final AppController appController;
  final DeviceController? deviceController;
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

  /// Places visited; the app's own by default (no row without one).
  final PlacesVisitedService? placesVisited;

  /// Spoken answers and its "Try it"; the app's own by default (no row without them).
  final SpokenAnswersStore? spokenAnswers;
  final Future<void> Function()? onTrySpeaking;

  /// The voice chosen and whether the plan has natural voices; the app's own by default.
  final SpokenVoiceStore? spokenVoice;

  @override
  State<AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<AccountSheet> {
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
        widget.sessionController != null &&
        widget.networkPolicy != null &&
        widget.preferences != null;
    final coordinator = fullyInjected ? null : AppRuntime.coordinator;
    _deviceController =
        widget.deviceController ?? coordinator!.deviceController;
    _appController = widget.appController;
    _sessionController =
        widget.sessionController ?? coordinator!.sessionController;
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
      final connected =
          (await _api.getToolkits()).where((t) => t.connected).toList();
      if (mounted) {
        setState(() => _apps =
            connected.isEmpty ? null : connected.map((t) => t.name).join(', '));
      }
    } catch (_) {}
    await _loadPlan();
    await _loadWhatsApp();
  }

  /// "WhatsApp, Gmail": what Apps has connected, WhatsApp first when it is linked.
  String? get _appsLine {
    final names = [
      if (_whatsapp case final whatsapp?
          when whatsapp.available && whatsapp.isLinked)
        'WhatsApp',
      if (_apps case final apps?) apps,
    ];
    return names.isEmpty ? null : names.join(', ');
  }

  /// At the top of Apps: what needs no account elsewhere, the phone's own apps and
  /// WhatsApp (linked from here).
  List<Widget> _phoneApps(PhoneActionsService? phoneActions) => [
        if (phoneActions != null)
          SettingsRow(
            key: const Key('apps-phone'),
            icon: PhoneWords.isIPhone
                ? Icons.phone_iphone_rounded
                : Icons.phone_android_rounded,
            title: PhoneWords.onThisPhone,
            subtitle: PhoneWords.isIPhone
                ? 'Reminders and Calendar, for Echo to use.'
                : 'The calendar, for Echo to use.',
            onTap: () =>
                _pushOnPage(PhoneAppsScreen(phoneActions: phoneActions)),
          ),
        if (_whatsapp case final whatsapp? when whatsapp.available)
          SettingsRow(
            key: const Key('apps-whatsapp'),
            icon: Icons.chat_outlined,
            title: 'WhatsApp',
            subtitle: whatsAppText(whatsapp),
            onTap: () async {
              await _pushOnPage(WhatsAppScreen(api: _api));
              await _loadWhatsApp();
            },
          ),
      ];

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
      // Echo's natural voices, and the choice of a voice, come with the plan
      await (widget.spokenVoice ?? AppRuntime.maybeCoordinator?.spokenVoice)
          ?.setPremium(plan.premiumVoice);
      if (mounted) setState(() => _plan = plan);
    } catch (_) {}
  }

  Future<void> _setMuted(bool muted) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _deviceController.setMuted(muted);
    } catch (_) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Echo could not update the microphone.')));
    }
  }

  /// Closes the sheet, then opens a screen on the page it came from (under the tab bar).
  /// Opens a settings page over the sheet (the root navigator): back comes to the sheet,
  /// not to the tab underneath.
  Future<void> _pushBuilder(WidgetBuilder builder) =>
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: builder));

  Future<void> _push(Widget page) => _pushBuilder((_) => page);

  /// From inside a page the sheet opened: on top of it, on the same navigator.
  Future<void> _pushOnPage(Widget page) => _push(page);

  void _openDevice() {
    final pageContext = widget.pageContext;
    Navigator.of(context).pop();
    unawaited(openEchoDevice(
      pageContext,
      appController: _appController,
      deviceController: _deviceController,
      preferences: _preferences,
      onRequireOnboarding: widget.onRequireOnboarding,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final phoneActions = AppRuntime.maybeCoordinator?.phoneActions;
    final places =
        widget.placesVisited ?? AppRuntime.maybeCoordinator?.placesVisited;
    final language = spokenLanguages[
        _preferences.getString(SpokenLanguageStore.key) ?? _account?.language];
    return ColoredBox(
      color: palette.background,
      child: ListView(
        key: const Key('account-sheet'),
        shrinkWrap: true,
        padding:
            EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          ValueListenableBuilder<AppViewState>(
            valueListenable: _appController,
            builder: (context, state, _) => _PendantCard(
              status: state.device,
              onOpen: _openDevice,
              onMute: _setMuted,
            ),
          ),
          const SettingsSection('ECHO DOES'),
          SettingsGroup(children: [
            SettingsRow(
              key: const Key('account-routines'),
              icon: Icons.schedule_rounded,
              title: 'Routines',
              subtitle: 'What Echo does on its own, and when.',
              onTap: () => _push(RoutinesScreen(
                onOpenResults: (id) =>
                    _appController.requestOpenRoutines(routineId: id),
                onOpenThread: _appController.requestOpenThread,
              )),
            ),
            SettingsRow(
              icon: Icons.extension_outlined,
              title: 'Apps',
              subtitle: _appsLine == null
                  ? 'WhatsApp, Reminders, Calendar and the apps Echo can act in.'
                  : null,
              value: _appsLine,
              onTap: () => _pushBuilder(
                widget.integrationsBuilder ??
                    (_) => IntegrationsScreen(extras: _phoneApps(phoneActions)),
              ),
            ),
            if (_whatsapp case final whatsapp? when whatsapp.available)
              SettingsRow(
                key: const Key('account-whatsapp'),
                icon: Icons.chat_outlined,
                title: 'WhatsApp',
                subtitle: whatsAppText(whatsapp),
                onTap: () => _push(WhatsAppScreen(api: _api)),
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
            if (widget.spokenAnswers ??
                    AppRuntime.maybeCoordinator?.spokenAnswers
                case final spoken?)
              ValueListenableBuilder<SpokenAnswers>(
                valueListenable: spoken,
                builder: (context, choice, _) => SettingsRow(
                  key: const Key('account-spoken-answers'),
                  icon: Icons.record_voice_over_outlined,
                  title: 'Spoken answers',
                  subtitle: spokenAnswersText(choice),
                  onTap: () => _push(SpokenAnswersScreen(
                    store: spoken,
                    onTry: widget.onTrySpeaking ??
                        AppRuntime.maybeCoordinator?.answerSpeaker.sample ??
                        () async {},
                    voices: AppRuntime.maybeCoordinator?.phoneVoice,
                    voiceStore: widget.spokenVoice ??
                        AppRuntime.maybeCoordinator?.spokenVoice,
                    naturalVoices: _api.naturalVoices,
                    language:
                        _preferences.getString(SpokenLanguageStore.key) ?? 'en',
                  )),
                ),
              ),
            SettingsRow(
              icon: Icons.history_rounded,
              title: 'Activity',
              subtitle: 'What Echo did in your apps.',
              onTap: () => _pushBuilder(
                  widget.activityBuilder ?? (_) => const ActionLogScreen()),
            ),
          ]),
          const SettingsSection('YOU'),
          SettingsGroup(children: [
            SettingsRow(
              key: const Key('account-about-you'),
              icon: Icons.psychology_outlined,
              title: 'About you',
              subtitle:
                  'What Echo knows about you, how it talks to you, your documents.',
              onTap: () => _push(MemoryScreen(
                facts: _api,
                documents: _api,
                instructions: _api,
                account: _api,
                knownAccount: _account,
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
              key: const Key('account-assistants'),
              icon: Icons.smart_toy_outlined,
              title: 'Assistants',
              subtitle: 'Echo for work, diet, sleep, or what you choose.',
              onTap: () => _push(AssistantsScreen(
                api: _api,
                documents: _api,
                onChanged: _appController.assistantsEdited,
              )),
            ),
            SettingsRow(
              key: const Key('account-language'),
              icon: Icons.translate_rounded,
              title: 'Language',
              value: language,
              subtitle: language == null ? 'The language you speak.' : null,
              onTap: () => _push(LanguageSettingsScreen(
                store:
                    SpokenLanguageStore(api: _api, preferences: _preferences),
              )),
            ),
          ]),
          const SettingsSection('SETTINGS'),
          SettingsGroup(children: [
            ValueListenableBuilder<AppViewState>(
              valueListenable: _appController,
              builder: (context, state, _) => SettingsRow(
                icon: Icons.contrast_rounded,
                title: 'Appearance',
                subtitle: switch (state.themePreference) {
                  ThemePreference.system =>
                    'System: light by day, dark at night',
                  ThemePreference.light => 'Light',
                  ThemePreference.dark => 'Dark',
                },
                onTap: () => _push(
                    AppearanceSettingsScreen(appController: _appController)),
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
            if (places != null)
              ValueListenableBuilder<bool>(
                valueListenable: places.on,
                builder: (context, on, _) => SettingsRow(
                  key: const Key('account-places'),
                  icon: Icons.place_outlined,
                  title: 'Places visited',
                  subtitle: on
                      ? 'On: where you stayed, kept for 90 days.'
                      : 'Off. Echo can note where you stay.',
                  onTap: () =>
                      _push(PlacesVisitedScreen(places: places, api: _api)),
                ),
              ),
            SettingsRow(
              key: const Key('account-health'),
              icon: Icons.favorite_border_rounded,
              title: 'Health',
              subtitle: 'Sleep, steps and workouts, from the Health app.',
              onTap: () => _push(HealthScreen(api: _api)),
            ),
            if (_plan case final plan?)
              SettingsRow(
                key: const Key('account-plan'),
                icon: Icons.data_usage_rounded,
                title: 'Plan',
                value: plan.name,
                subtitle: plan.usageLine,
                onTap: () => _push(PlanScreen(api: _api, initial: plan)),
              ),
            SettingsRow(
              icon: Icons.devices_rounded,
              title: 'Devices',
              subtitle: 'Phones, and assistants that read your memory.',
              onTap: () => _pushBuilder(
                  widget.devicesBuilder ?? (_) => const DevicesScreen()),
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
              onTap: () => _pushBuilder(
                widget.diagnosticsBuilder ??
                    (_) => const DeviceMessagesScreen(),
              ),
            ),
            SettingsRow(
              icon: Icons.auto_awesome_outlined,
              title: 'What Echo can do',
              subtitle: 'Examples to try, by chat and by voice.',
              onTap: () => _push(CapabilitiesScreen(
                onAsk: _appController.requestAsk,
                onOpenVoices: () => _pushOnPage(const VoiceSettingsScreen()),
              )),
            ),
            SettingsRow(
              key: const Key('account-example-data'),
              icon: Icons.auto_awesome_motion_outlined,
              title: 'Example data',
              subtitle: 'A few example days, to see Echo filled in.',
              onTap: () => _push(ExampleDataScreen(api: _api)),
            ),
            SettingsRow(
              icon: Icons.info_outline_rounded,
              title: 'About',
              subtitle: switch (_account?.email) {
                final email? => 'Signed in as $email',
                null => 'Version, licenses and your account.',
              },
              onTap: () => _push(AboutSettingsScreen(
                appController: _appController,
                sessionController: _sessionController,
                onLoggedOut: widget.onRequireOnboarding ?? () {},
                deleteWithGoogle: _account?.hasPassword == false,
                deleteAccount: (password) async {
                  final api = (widget.apiServiceFactory ?? ApiService.new)();
                  try {
                    if (password != null) {
                      await api.deleteAccount(password: password);
                    } else {
                      final token = await GoogleIdentity.idToken();
                      if (token == null) throw const DeletionCancelled();
                      await api.deleteAccount(googleIdToken: token);
                    }
                  } finally {
                    if (widget.apiServiceFactory == null) api.dispose();
                  }
                },
              )),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Echo in a card: its state, battery, segments waiting and firmware, and Mute. A tap on
/// the card opens the Echo screen.
final class _PendantCard extends StatelessWidget {
  const _PendantCard(
      {required this.status, required this.onOpen, required this.onMute});

  final DeviceStatus status;
  final VoidCallback onOpen;
  final ValueChanged<bool> onMute;

  static String stateLabel(DeviceConnectionState state) => switch (state) {
        DeviceConnectionState.listening => 'Listening',
        DeviceConnectionState.muted => 'Muted',
        DeviceConnectionState.turningOff => 'Turning off',
        DeviceConnectionState.off => 'Off',
        DeviceConnectionState.scanning ||
        DeviceConnectionState.connecting ||
        DeviceConnectionState.bonding ||
        DeviceConnectionState.reconnecting =>
          'Connecting',
        DeviceConnectionState.bluetoothOff => 'Bluetooth is off',
        DeviceConnectionState.offline ||
        DeviceConnectionState.error =>
          'Offline',
        DeviceConnectionState.unpaired => 'Not paired',
      };

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final state = status.connectionState;
    final line = [
      stateLabel(state),
      if (status.batteryPercent case final battery?) 'battery $battery%',
      if (status.bufferCount > 0) '${status.bufferCount} waiting',
      if (status.firmwareVersion case final firmware?) 'firmware $firmware',
    ].join(' · ');
    final radius = BorderRadius.circular(AppTheme.panelRadius);
    final live = state == DeviceConnectionState.listening;
    final canMute = live || state == DeviceConnectionState.muted;
    return Padding(
      key: const Key('account-pendant'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Material(
        color: palette.surface,
        borderRadius: radius,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                key: const Key('account-pendant-open'),
                borderRadius: radius,
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.topCenter,
                        padding: const EdgeInsets.only(top: 8),
                        decoration: BoxDecoration(
                            color: palette.surface2,
                            shape: BoxShape.circle),
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: live ? palette.accent : null,
                            border: live
                                ? null
                                : Border.all(
                                    color: palette.text2, width: 1.5),
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
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Text('Mute',
                        style: textTheme.labelSmall
                            ?.copyWith(color: palette.text2)),
                  ),
                  Semantics(
                    label: 'Mute',
                    child: Switch(
                      key: const Key('account-mute'),
                      value: state == DeviceConnectionState.muted,
                      onChanged: canMute ? onMute : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
