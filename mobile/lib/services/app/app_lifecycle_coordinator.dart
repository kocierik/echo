import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/device_status.dart';
import '../api/api_service.dart';
import 'app_controller.dart';
import '../device/ble_service.dart';
import '../device/device_controller.dart';
import '../device/device_identity_store.dart';
import 'network_policy.dart';
import 'notification_scheduler.dart';
import 'notification_service.dart';
import '../device/photo_service.dart';
import 'session_controller.dart';
import 'spoken_answers_store.dart';
import 'spoken_language.dart';
import 'spoken_voice_store.dart';
import '../chat/voice_updates_service.dart';
import '../api/response_cache.dart';
import '../device/device_command_loop.dart';
import '../device/firmware_update.dart';
import '../phone/answer_speaker.dart';
import '../phone/natural_voice.dart';
import '../phone/phone_actions.dart';
import '../phone/phone_calendar.dart';
import '../phone/phone_location.dart';
import '../phone/places_visited.dart';
import '../phone/visit_sources.dart';
import '../device/live_activity_service.dart';
import '../device/phone_camera.dart';
import '../device/phone_words.dart';

typedef LifecycleObserverCallback = void Function(WidgetsBindingObserver);

final class AppLifecycleCoordinator {
  AppLifecycleCoordinator._({
    required this.bleService,
    required this.deviceController,
    required this.sessionController,
    required this.appController,
    required this.networkPolicy,
    required this.preferences,
    required this.notificationService,
    required this.photoService,
    required this.phoneActions,
    required this.phoneLocation,
    required this.placesVisited,
    required this.spokenAnswers,
    required this.spokenVoice,
    required this.phoneVoice,
    required this.answerSpeaker,
    required StreamSubscription<DeviceStatus> speakerSubscription,
    required VoidCallback onDictation,
    required DeviceCommandLoop commandLoop,
    required this.notificationScheduler,
    required this.liveActivity,
    required this.firmwareUpdate,
    required ApiService credentialApiService,
    required AppLifecycleBinding binding,
    required StreamSubscription<DeviceStatus> firmwareSubscription,
  })  : _credentialApiService = credentialApiService,
        _speakerSubscription = speakerSubscription,
        _onDictation = onDictation,
        _commandLoop = commandLoop,
        _binding = binding,
        _firmwareSubscription = firmwareSubscription;

  final BleService bleService;
  final DeviceController deviceController;
  final SessionController sessionController;
  final AppController appController;
  final NetworkPolicy networkPolicy;
  final SharedPreferences preferences;
  final NotificationService notificationService;
  final PhotoService photoService;

  /// Reminders and Calendar on this iPhone (Profile → On this iPhone).
  final PhoneActionsService phoneActions;

  /// Where the phone is, only for a thing saved with its place (Saved).
  final PhoneLocationService phoneLocation;

  /// The places where the user stayed, when they turned it on (Profile → Places visited).
  final PlacesVisitedService placesVisited;

  /// Profile → Spoken answers, and the voice that reads the answers aloud.
  final SpokenAnswersStore spokenAnswers;

  /// The voice chosen for each language, and the phone's voices to choose from.
  final SpokenVoiceStore spokenVoice;
  final VoiceCatalog phoneVoice;
  final AnswerSpeaker answerSpeaker;
  final StreamSubscription<DeviceStatus> _speakerSubscription;
  final VoidCallback _onDictation;
  final DeviceCommandLoop _commandLoop;

  /// Briefings, promises and the evening recap, scheduled on the phone.
  final NotificationScheduler notificationScheduler;

  /// The wearable on the Lock Screen (iOS 16.1+).
  final LiveActivityService liveActivity;

  /// New wearable firmware from the server, installed over Bluetooth when the user asks.
  final FirmwareUpdateController firmwareUpdate;
  final StreamSubscription<DeviceStatus> _firmwareSubscription;
  final ApiService _credentialApiService;
  final AppLifecycleBinding _binding;
  bool _disposed = false;

  static const allowCellularPreferenceKey = 'echo_allow_cellular';

  static NetworkPolicy networkPolicyFrom(SharedPreferences preferences) {
    return NetworkPolicy(
      allowCellular:
          preferences.getBool(allowCellularPreferenceKey) ?? true,
    );
  }

  static Future<AppLifecycleCoordinator> create() async {
    await FlutterBluePlus.setOptions(restoreState: true);
    final preferences = await SharedPreferences.getInstance();
    final networkAccess = ConnectivityNetworkAccess();
    final networkPolicy = networkPolicyFrom(preferences);
    AppController? tapTarget;
    String? earlyTap;
    final notificationPort = FlutterLocalNotificationPort(
      onSelect: (payload) {
        // "voice:<sessionId>" opens that session in the Ask tab
        final target = tapTarget;
        if (target != null) {
          target.handleNotificationPayload(payload);
        } else {
          earlyTap = payload;
        }
      },
    );
    final notificationService = NotificationService(notificationPort);
    await notificationService.initialize();
    final bleService = BleService(
      networkAccess: networkAccess,
      networkPolicy: networkPolicy,
    );
    final identityStore = DeviceIdentityStore(preferences);
    final credentialStore = SharedPreferencesApiCredentialStore(
      preferences: () async => preferences,
    );
    final deviceController = DeviceController(
      ble: bleService,
      identityStore: identityStore,
      // Signed out (the welcome, before an account): the saved wearable is left alone
      canConnect: () => credentialStore.configured,
    );
    final credentialApiService = ApiService(credentialStore: credentialStore);
    final sessionController = SessionController(
      // A key revoked from another phone signs this one out
      unauthorized: ApiClient.unauthorized,
      bleStopper: DeviceControllerBleStopper(deviceController),
      apiCredentials: ApiServiceCredentialsClearer(credentialApiService),
      deviceIdentity: DeviceIdentityStoreClearer(identityStore),
      sessionCache: SharedPreferencesSessionCacheClearer(
        preferences,
        responses: FileResponseCache.shared,
      ),
    );
    final appController = AppController(
      initialDevice: deviceController.state,
      deviceStates: deviceController.stateStream,
      initialSession: sessionController.state,
      sessionStates: sessionController.stream,
      preferences: SharedPreferencesAppPreferences(preferences),
    );
    await appController.initialize();
    tapTarget = appController;
    // Cold start from a notification tap: route it like a tap while running.
    String? launchPayload;
    try {
      launchPayload = await notificationPort.launchPayload();
    } catch (_) {}
    for (final payload in [launchPayload, earlyTap]) {
      if (payload != null) appController.handleNotificationPayload(payload);
    }
    // Wearable camera: JPEGs from the wearable (TAKE_PHOTO comes with the commands)
    final photoService = PhotoService(
      api: credentialApiService,
      device: bleService,
      // The camera button still works without the wearable (not connected, muted)
      phoneCamera: ImagePickerPhoneCamera(),
    );
    bleService.photoUploader = photoService.uploadFromDevice;
    bleService.onPhotoFailed = photoService.onDeviceFailure;
    // As soon as a photo arrives, the user is told it was taken: a buzz, or a notification
    // with the app in the background
    bleService.onPhotoStarted = ShutterFeedback(
      notify: notificationService.showPhotoTaken,
      inForeground: () =>
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    ).photoStarted;
    // Reminders and Calendar on this iPhone, when the user turned them on
    final phoneActions = PhoneActionsService(
      calendar: EventKitPhoneCalendar(),
      choices: PhoneAppChoices(preferences),
      commands: credentialApiService,
      server: credentialApiService,
    );
    unawaited(phoneActions.report(force: true));
    // The place of a thing being saved, read only when the server asks for it
    final phoneLocation = PhoneLocationService(
      reader: const GeolocatorReader(),
      commands: credentialApiService,
      saved: credentialApiService,
      inForeground: () =>
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      notifyOpen: notificationService.showSavePlace,
    );
    // Places visited, off by default: iOS's visits, or stays from Android's positions
    final placesVisited = PlacesVisitedService(
      source: PhoneWords.isIPhone
          ? IosVisitSource()
          : AndroidStaySource(
              location: const GeolocatorAndroidLocation(),
              store: PreferencesStayStore(preferences),
            ),
      api: credentialApiService,
      preferences: preferences,
      networkAccess: networkAccess,
      networkPolicy: networkPolicy,
      geocode: const GeolocatorReader().address,
    );
    unawaited(placesVisited.resume());
    // The server's commands: photos for the wearable, actions for this iPhone
    // Set below: a routine's answer is checked (and notified) when its nudge arrives
    late final VoiceUpdatesService voiceUpdates;
    final commandLoop = DeviceCommandLoop(
      api: credentialApiService,
      onTakePhoto: photoService.handleTakePhoto,
      onPhoneAction: phoneActions.handle,
      onVoiceUpdate: () => voiceUpdates.check(),
      onGetLocation: phoneLocation.handle,
      onPersonBrief: PersonBriefs(
        notifications: notificationService,
        preferences: NotificationPreferences(preferences),
      ).show,
    )..start();
    final notificationScheduler = NotificationScheduler(
      api: credentialApiService,
      notifications: notificationService,
      preferences: NotificationPreferences(preferences),
      phoneEvents: phoneActions.upcomingEvents,
    );
    unawaited(notificationScheduler.refresh(force: true));
    final notificationChoices = NotificationPreferences(preferences);
    final liveActivity = LiveActivityService(
      initial: deviceController.state,
      statuses: deviceController.stateStream,
      // On Android it is the foreground service that keeps Echo connected: always on
      enabled: () => !PhoneWords.isIPhone || notificationChoices.liveActivity,
    )..start();
    final firmwareUpdate = FirmwareUpdateController(
      api: credentialApiService,
      link: bleService,
      device: () => deviceController.state,
    );
    final firmwareSubscription = deviceController.stateStream
        .listen((_) => firmwareUpdate.deviceChanged());
    unawaited(firmwareUpdate.check());
    final spokenAnswers = SpokenAnswersStore(preferences);
    final spokenVoice = SpokenVoiceStore(preferences);
    final phoneVoice = FlutterTtsVoice(null, spokenVoice.voiceFor);
    final answerSpeaker = AnswerSpeaker(
      // Echo's natural voice on Plus when chosen, else (and offline) the phone's
      voice: NaturalVoice(api: credentialApiService, phone: phoneVoice, store: spokenVoice),
      output: const ChannelAudioOutput(),
      setting: spokenAnswers,
      preferences: preferences,
      language: () => preferences.getString(SpokenLanguageStore.key) ?? 'en',
      mic: DeviceEchoMic(deviceController),
      quiet: appController.askDictation,
    );
    // Echo found muted (often on reconnecting) may have been left so by an answer
    final speakerSubscription = deviceController.stateStream.listen(
      (status) => unawaited(answerSpeaker.deviceSeen(status.connectionState)),
    );
    unawaited(answerSpeaker.recover());
    // Holding Ask to dictate: the phone stops talking
    void onDictation() {
      if (appController.askDictation.value) unawaited(answerSpeaker.stop());
    }

    appController.askDictation.addListener(onDictation);
    voiceUpdates = VoiceUpdatesService(
      credentialApiService,
      notificationService,
      preferences,
      onNewMessages: appController.threadChanged,
      onNewRuns: appController.routineRunsFound,
      onNewAnswer: (answer) => unawaited(answerSpeaker.say(answer)),
    );
    final binding = await startBinding(
      initialStatus: deviceController.state,
      statusStream: deviceController.stateStream,
      uploadFailureStream: bleService.uploadFailureStream,
      segmentUploadedStream: bleService.segmentUploadedStream,
      notifications: notificationService,
      networkAccess: networkAccess,
      startController: deviceController.start,
      reconnectOnResume: deviceController.reconnect,
      onWake: () async {
        await answerSpeaker.recover();
        await voiceUpdates.check();
        await notificationScheduler.refresh();
        await firmwareUpdate.check();
        await phoneActions.report();
        // On screen again: the place a save could not read in the background
        await phoneLocation.onResumed();
        // Stays waiting for the network (or for Wi-Fi)
        await placesVisited.flush();
      },
    );
    return AppLifecycleCoordinator._(
      bleService: bleService,
      deviceController: deviceController,
      sessionController: sessionController,
      appController: appController,
      networkPolicy: networkPolicy,
      preferences: preferences,
      notificationService: notificationService,
      photoService: photoService,
      phoneActions: phoneActions,
      phoneLocation: phoneLocation,
      placesVisited: placesVisited,
      spokenAnswers: spokenAnswers,
      spokenVoice: spokenVoice,
      phoneVoice: phoneVoice,
      answerSpeaker: answerSpeaker,
      speakerSubscription: speakerSubscription,
      onDictation: onDictation,
      commandLoop: commandLoop,
      notificationScheduler: notificationScheduler,
      liveActivity: liveActivity,
      firmwareUpdate: firmwareUpdate,
      credentialApiService: credentialApiService,
      binding: binding,
      firmwareSubscription: firmwareSubscription,
    );
  }

  static Future<AppLifecycleBinding> startBinding({
    required DeviceStatus initialStatus,
    required Stream<DeviceStatus> statusStream,
    required Stream<int> uploadFailureStream,
    required Stream<int> segmentUploadedStream,
    required NotificationService notifications,
    required NetworkAccess networkAccess,
    required Future<void> Function() startController,
    Future<void> Function()? reconnectOnResume,
    Future<void> Function()? onWake,
    LifecycleObserverCallback? addObserver,
    LifecycleObserverCallback? removeObserver,
    DateTime Function()? clock,
  }) async {
    final binding = AppLifecycleBinding(
      initialStatus: initialStatus,
      statusStream: statusStream,
      uploadFailureStream: uploadFailureStream,
      segmentUploadedStream: segmentUploadedStream,
      notifications: notifications,
      networkAccess: networkAccess,
      reconnectOnResume: reconnectOnResume,
      onWake: onWake,
      addObserver: addObserver ?? WidgetsBinding.instance.addObserver,
      removeObserver: removeObserver ?? WidgetsBinding.instance.removeObserver,
      clock: clock,
    );
    await startController();
    return binding;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _commandLoop.stop();
    await _speakerSubscription.cancel();
    appController.askDictation.removeListener(_onDictation);
    await answerSpeaker.stop();
    spokenAnswers.dispose();
    spokenVoice.dispose();
    photoService.dispose();
    placesVisited.dispose();
    await liveActivity.dispose();
    await _firmwareSubscription.cancel();
    firmwareUpdate.dispose();
    appController.dispose();
    await _binding.dispose();
    await sessionController.dispose();
    _credentialApiService.dispose();
    await deviceController.dispose();
  }
}

final class AppLifecycleBinding with WidgetsBindingObserver {
  AppLifecycleBinding({
    required DeviceStatus initialStatus,
    required Stream<DeviceStatus> statusStream,
    required Stream<int> uploadFailureStream,
    required Stream<int> segmentUploadedStream,
    required NotificationService notifications,
    required NetworkAccess networkAccess,
    Future<void> Function()? reconnectOnResume,
    Future<void> Function()? onWake,
    required LifecycleObserverCallback addObserver,
    required LifecycleObserverCallback removeObserver,
    DateTime Function()? clock,
  })  : _notifications = notifications,
        _clock = clock ?? DateTime.now,
        _networkAccess = networkAccess,
        _reconnectOnResume = reconnectOnResume,
        _onWake = onWake,
        _removeObserver = removeObserver,
        _droppedSegments = initialStatus.droppedSegments,
        _notifiedDropped = initialStatus.droppedSegments {
    _statusSubscription = statusStream.listen(_onStatus);
    _uploadFailureSubscription = uploadFailureStream.listen(_onUploadFailure);
    _segmentUploadedSubscription = segmentUploadedStream.listen((_) {
      _uploadFailureNotificationShown = false;
      _wake();
    });
    addObserver(this);
  }

  final NotificationService _notifications;
  final NetworkAccess _networkAccess;
  final Future<void> Function()? _reconnectOnResume;
  final Future<void> Function()? _onWake;
  final LifecycleObserverCallback _removeObserver;
  late final StreamSubscription<DeviceStatus> _statusSubscription;
  late final StreamSubscription<int> _uploadFailureSubscription;
  late final StreamSubscription<int> _segmentUploadedSubscription;
  final DateTime Function() _clock;
  int _droppedSegments;

  /// The dropped count the last loss notification covered, and when it was shown: a
  /// full wearable drops one segment per new one and reports each, so at most one
  /// notification per [lossNotificationGap], saying how many since the last.
  int _notifiedDropped;
  DateTime? _lossNotifiedAt;
  static const lossNotificationGap = Duration(minutes: 30);
  bool _uploadFailureNotificationShown = false;
  bool _disposed = false;

  void _onStatus(DeviceStatus status) {
    if (_disposed) return;
    switch (status.connectionState) {
      case DeviceConnectionState.listening:
      case DeviceConnectionState.muted:
        unawaited(_notifications.cancelDisconnected());
      case DeviceConnectionState.reconnecting:
      case DeviceConnectionState.offline:
        unawaited(_notifications.scheduleDisconnected());
      case DeviceConnectionState.unpaired:
      case DeviceConnectionState.bluetoothOff:
      case DeviceConnectionState.scanning:
      case DeviceConnectionState.connecting:
      case DeviceConnectionState.bonding:
      case DeviceConnectionState.error:
        break;
    }

    if (status.droppedSegments < _droppedSegments) {
      // The wearable restarted: its counter starts again from here
      _droppedSegments = status.droppedSegments;
      _notifiedDropped = status.droppedSegments;
    } else if (status.droppedSegments > _droppedSegments) {
      _droppedSegments = status.droppedSegments;
      final now = _clock();
      final last = _lossNotifiedAt;
      if (last == null || now.difference(last) >= lossNotificationGap) {
        unawaited(_notifications.showLoss(status.droppedSegments - _notifiedDropped));
        _notifiedDropped = status.droppedSegments;
        _lossNotifiedAt = now;
      }
    }
  }

  void _onUploadFailure(int consecutiveFailures) {
    if (_disposed ||
        consecutiveFailures < 3 ||
        _uploadFailureNotificationShown) {
      return;
    }
    _uploadFailureNotificationShown = true;
    unawaited(_notifications.showUploadFailure());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshNetworkTypes());
      final reconnect = _reconnectOnResume;
      if (reconnect != null) {
        unawaited(reconnect());
      }
      _wake();
    }
  }

  void _wake() {
    final wake = _onWake;
    if (_disposed || wake == null) return;
    unawaited(() async {
      try {
        await wake();
      } catch (_) {}
    }());
  }

  Future<void> _refreshNetworkTypes() async {
    try {
      await _networkAccess.currentTypes();
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _removeObserver(this);
    await _statusSubscription.cancel();
    await _uploadFailureSubscription.cancel();
    await _segmentUploadedSubscription.cancel();
  }
}