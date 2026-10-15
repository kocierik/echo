import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/app_view_state.dart';
import 'models/device_status.dart';
import 'screens/home_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/memories_screen.dart';
import 'screens/tasks_screen.dart';
import 'services/api/api_service.dart';
import 'services/app/app_controller.dart';
import 'services/app/app_lifecycle_coordinator.dart';
import 'services/app/app_runtime.dart';
import 'services/device/ble_service.dart';
import 'services/device/device_ble_port.dart';
import 'services/device/device_controller.dart';
import 'services/device/device_identity_store.dart';
import 'services/onboarding/onboarding_adapters.dart';
import 'services/onboarding/onboarding_controller.dart';
import 'services/onboarding/onboarding_permissions_service.dart';
import 'services/app/network_policy.dart';
import 'services/app/notification_service.dart';
import 'services/app/session_controller.dart';
import 'theme/app_theme.dart';
import 'widgets/echo_app_shell.dart';
import 'widgets/device_pill.dart';
import 'widgets/person_request_listener.dart';
import 'widgets/tasks_request_listener.dart';

late AppLifecycleCoordinator appLifecycleCoordinator;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Archivo (SIL Open Font License), listed in About → Licenses
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/fonts/OFL-Archivo.txt');
    yield LicenseEntryWithLineBreaks(const ['Archivo'], license);
  });
  appLifecycleCoordinator = await AppLifecycleCoordinator.create();
  AppRuntime.initialize(appLifecycleCoordinator);
  bleService = appLifecycleCoordinator.bleService;
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF080A0D),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const EchoApp());
}

class EchoApp extends StatelessWidget {
  const EchoApp({
    this.appController,
    this.deviceController,
    this.sessionController,
    this.networkPolicy,
    this.preferences,
    this.segmentUploadedStream,
    this.onboardingControllerFactory,
    super.key,
  });

  final AppController? appController;
  final DeviceController? deviceController;
  final SessionController? sessionController;
  final NetworkPolicy? networkPolicy;
  final SharedPreferences? preferences;
  final Stream<Object?>? segmentUploadedStream;
  final OnboardingController Function()? onboardingControllerFactory;

  @override
  Widget build(BuildContext context) {
    final coordinator = appController == null ? appLifecycleCoordinator : null;
    final controller = appController ?? coordinator!.appController;
    final shellDeviceController =
        deviceController ?? coordinator?.deviceController;
    final shellSessionController =
        sessionController ?? coordinator?.sessionController;
    final shellNetworkPolicy = networkPolicy ?? coordinator?.networkPolicy;
    final shellPreferences = preferences ?? coordinator?.preferences;
    final shellSegmentUploadedStream =
        segmentUploadedStream ?? coordinator?.bleService.segmentUploadedStream;
    final onboardingFactory = onboardingControllerFactory ??
        (coordinator == null
            ? null
            : () => _createDefaultOnboardingController(coordinator));
    if (onboardingFactory == null) {
      throw StateError(
        'An onboardingControllerFactory is required with an injected AppController.',
      );
    }
    return ValueListenableBuilder<AppViewState>(
      valueListenable: controller,
      builder: (context, state, child) {
        return MaterialApp(
          title: 'Echo',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: controller.themeMode,
          home: AppRouter(
            key: ValueKey(state.session.loggedOut),
            appController: controller,
            deviceController: shellDeviceController,
            sessionController: shellSessionController,
            networkPolicy: shellNetworkPolicy,
            preferences: shellPreferences,
            segmentUploadedStream: shellSegmentUploadedStream,
            onboardingControllerFactory: onboardingFactory,
          ),
          builder: (context, child) {
            final brightness = Theme.of(context).brightness;
            final iconBrightness = brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: iconBrightness,
                statusBarBrightness: brightness,
                systemNavigationBarColor: EchoPalette.of(context).background,
                systemNavigationBarIconBrightness: iconBrightness,
              ),
              child: child!,
            );
          },
        );
      },
    );
  }
}

class AppRouter extends StatefulWidget {
  const AppRouter({
    required this.appController,
    required this.onboardingControllerFactory,
    this.deviceController,
    this.sessionController,
    this.networkPolicy,
    this.preferences,
    this.segmentUploadedStream,
    super.key,
  });

  final AppController appController;
  final DeviceController? deviceController;
  final SessionController? sessionController;
  final NetworkPolicy? networkPolicy;
  final SharedPreferences? preferences;
  final Stream<Object?>? segmentUploadedStream;
  final OnboardingController Function() onboardingControllerFactory;

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  bool _loading = true;
  bool _onboardingComplete = false;
  late OnboardingController _onboardingController;
  int _onboardingGeneration = 0;

  @override
  void initState() {
    super.initState();
    _onboardingController = widget.onboardingControllerFactory();
    _initializeOnboarding(_onboardingController, _onboardingGeneration);
  }

  Future<void> _initializeOnboarding(
    OnboardingController controller,
    int generation, {
    bool resumePairingIfConfigured = false,
  }) async {
    await controller.initialize(
      resumePairingIfConfigured: resumePairingIfConfigured,
    );
    if (!mounted || generation != _onboardingGeneration) return;
    setState(() {
      _onboardingComplete = controller.value.completed;
      _loading = false;
    });
  }

  Future<void> _restartOnboarding() async {
    final generation = ++_onboardingGeneration;
    final previous = _onboardingController;
    final replacement = widget.onboardingControllerFactory();
    _onboardingController = replacement;
    previous.dispose();
    if (mounted) {
      setState(() {
        _loading = true;
        _onboardingComplete = false;
      });
    }
    await _initializeOnboarding(
      replacement,
      generation,
      resumePairingIfConfigured: true,
    );
  }

  @override
  void dispose() {
    _onboardingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        body: Center(
          child: Semantics(
            label: 'Loading setup progress',
            liveRegion: true,
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }
    if (!_onboardingComplete) {
      return OnboardingScreen(
        controller: _onboardingController,
        onComplete: () => setState(() => _onboardingComplete = true),
      );
    }
    return MainShell(
      appController: widget.appController,
      deviceController: widget.deviceController,
      sessionController: widget.sessionController,
      networkPolicy: widget.networkPolicy,
      preferences: widget.preferences,
      segmentUploadedStream: widget.segmentUploadedStream,
      onRequireOnboarding: _restartOnboarding,
    );
  }
}

OnboardingController _createDefaultOnboardingController(
  AppLifecycleCoordinator coordinator,
) {
  final api = ApiService(
    credentialStore: SharedPreferencesApiCredentialStore(
      preferences: () async => coordinator.preferences,
    ),
  );
  final permissions = DefaultOnboardingPermissions(
    notificationService: coordinator.notificationService,
    requestBluetoothAccess: () async {
      return coordinator.bleService.adapterState == DeviceAdapterState.on;
    },
  );
  final pairing = DeviceControllerOnboardingPairing(
    deviceController: coordinator.deviceController,
    hasIdentity: () async {
      final remoteId = coordinator.preferences.getString(
        DeviceIdentityStore.remoteIdKey,
      );
      return remoteId != null && remoteId.isNotEmpty;
    },
  );
  return OnboardingController(
    api: ApiServiceOnboardingApi(api),
    permissions: permissions,
    pairing: pairing,
    preferences: SharedPreferencesAppPreferences(coordinator.preferences),
    onDispose: () {
      permissions.dispose();
      api.dispose();
    },
  );
}

class MainShell extends StatelessWidget {
  const MainShell({
    required this.appController,
    this.deviceController,
    this.sessionController,
    this.networkPolicy,
    this.preferences,
    this.segmentUploadedStream,
    this.onSettingsTap,
    this.onRequireOnboarding,
    super.key,
  });

  final AppController appController;
  final DeviceController? deviceController;
  final SessionController? sessionController;
  final NetworkPolicy? networkPolicy;
  final SharedPreferences? preferences;
  final Stream<Object?>? segmentUploadedStream;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onRequireOnboarding;

  void _openSettings(BuildContext context) {
    if (onSettingsTap != null) {
      onSettingsTap!();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          deviceController: deviceController,
          appController: appController,
          sessionController: sessionController,
          networkPolicy: networkPolicy,
          preferences: preferences,
          onRequireOnboarding: onRequireOnboarding,
          onOpenTranscripts: () {
            unawaited(appController.setSelectedTab(AppController.memoriesTab));
          },
        ),
      ),
    );
  }

  void _openTasks(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TasksPage(
          segmentUploadedStream: segmentUploadedStream,
          onAsk: appController.requestAsk,
        ),
      ),
    );
  }

  /// The pill's long press: mute, or resume listening.
  Future<void> _toggleMute(BuildContext context, DeviceStatus status) async {
    final controller = deviceController;
    if (controller == null) return;
    final mute = status.connectionState == DeviceConnectionState.listening;
    final messenger = ScaffoldMessenger.of(context);
    unawaited(HapticFeedback.mediumImpact());
    void say(String message) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    try {
      await controller.setMuted(mute);
      say(mute ? 'Echo is muted. Hold the pill again to listen.' : 'Echo is listening again.');
    } catch (_) {
      say('Echo could not update the microphone.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PersonRequestListener(
      request: appController.pendingPersonId,
      onAsk: appController.requestAsk,
      child: TasksRequestListener(
        requests: appController.openTasksRequests,
        onOpen: () => _openTasks(context),
        child: ValueListenableBuilder<AppViewState>(
          valueListenable: appController,
          builder: (context, state, child) {
            final pill = DevicePill(
              status: state.device,
              onTap: () => _openSettings(context),
              onLongPress: deviceController == null
                  ? null
                  : () => unawaited(_toggleMute(context, state.device)),
            );
            return Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: appController.askDictation,
                builder: (context, dictating, _) => EchoAppShell(
                  selectedIndex: state.selectedTab,
                  dictating: dictating,
                  onDestinationSelected: (index) {
                    unawaited(appController.setSelectedTab(index));
                  },
                  onAskHold: appController.setAskDictation,
                  children: [
                    HomeScreen(
                      deviceStatus: state.device,
                      headerAction: pill,
                      onReconnect: deviceController?.reconnect,
                      onPair: onRequireOnboarding,
                      onAsk: appController.requestAsk,
                      onOpenChat: (sessionId) => sessionId == null
                          ? appController.handleNotificationPayload(
                              NotificationService.voicePayloadPrefix)
                          : appController.requestOpenSession(sessionId),
                      onOpenMemories: () {
                        unawaited(appController
                            .setSelectedTab(AppController.memoriesTab));
                      },
                      onOpenTasks: () => _openTasks(context),
                      segmentUploadedStream: segmentUploadedStream,
                      firmwareUpdate: AppRuntime.maybeCoordinator?.firmwareUpdate,
                      onOpenSettings: () => _openSettings(context),
                    ),
                    ChatScreen(
                      headerAction: pill,
                      dictation: appController.askDictation,
                      openSessionRequest: appController.pendingChatSessionId,
                      askRequest: appController.pendingChatQuestion,
                      photoTaker: AppRuntime.maybeCoordinator?.photoService,
                    ),
                    MemoriesScreen(
                      headerAction: pill,
                      segmentUploadedStream: segmentUploadedStream,
                      onAsk: appController.requestAsk,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
