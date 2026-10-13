import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_status.dart';
import 'api_service.dart';
import 'app_controller.dart';
import 'app_preferences.dart';
import 'ble_service.dart';
import 'device_controller.dart';
import 'device_identity_store.dart';
import 'network_policy.dart';
import 'notification_service.dart';
import 'session_controller.dart';
import 'voice_updates_service.dart';

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
    required ApiService credentialApiService,
    required AppLifecycleBinding binding,
  })  : _credentialApiService = credentialApiService,
        _binding = binding;

  final BleService bleService;
  final DeviceController deviceController;
  final SessionController sessionController;
  final AppController appController;
  final NetworkPolicy networkPolicy;
  final SharedPreferences preferences;
  final NotificationService notificationService;
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
    final notificationService = NotificationService(
      FlutterLocalNotificationPort(
        onSelect: (payload) {
          // Opening the specific Voice requests session would need a hook
          // into ChatScreen's controller; select the Ask tab instead.
          if (payload.startsWith(NotificationService.voicePayloadPrefix)) {
            final target = tapTarget;
            if (target != null) unawaited(target.setSelectedTab(2));
          }
        },
      ),
    );
    await notificationService.initialize();
    final bleService = BleService(
      networkAccess: networkAccess,
      networkPolicy: networkPolicy,
    );
    final identityStore = DeviceIdentityStore(preferences);
    final deviceController = DeviceController(
      ble: bleService,
      identityStore: identityStore,
    );
    final credentialApiService = ApiService(
      credentialStore: SharedPreferencesApiCredentialStore(
        preferences: () async => preferences,
      ),
    );
    final sessionController = SessionController(
      bleStopper: DeviceControllerBleStopper(deviceController),
      apiCredentials: ApiServiceCredentialsClearer(credentialApiService),
      deviceIdentity: DeviceIdentityStoreClearer(identityStore),
      sessionCache: SharedPreferencesSessionCacheClearer(preferences),
    );
    final appController = AppController(
      initialDevice: deviceController.state,
      deviceStates: deviceController.stateStream,
      initialSession: sessionController.state,
      sessionStates: sessionController.stream,
      preferences: SharedPreferencesAppPreferences(preferences),
    );
    tapTarget = appController;
    await appController.initialize();
    final voiceUpdates = VoiceUpdatesService(
      credentialApiService,
      notificationService,
      preferences,
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
      onWake: voiceUpdates.check,
    );
    return AppLifecycleCoordinator._(
      bleService: bleService,
      deviceController: deviceController,
      sessionController: sessionController,
      appController: appController,
      networkPolicy: networkPolicy,
      preferences: preferences,
      notificationService: notificationService,
      credentialApiService: credentialApiService,
      binding: binding,
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
    );
    await startController();
    return binding;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
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
  })  : _notifications = notifications,
        _networkAccess = networkAccess,
        _reconnectOnResume = reconnectOnResume,
        _onWake = onWake,
        _removeObserver = removeObserver,
        _droppedSegments = initialStatus.droppedSegments {
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
  int _droppedSegments;
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
      _droppedSegments = status.droppedSegments;
    } else if (status.droppedSegments > _droppedSegments) {
      _droppedSegments = status.droppedSegments;
      unawaited(_notifications.showLoss(status.droppedSegments));
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