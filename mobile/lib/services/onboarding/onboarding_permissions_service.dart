import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../app/notification_service.dart';
import 'onboarding_controller.dart';

final class DefaultOnboardingPermissions implements OnboardingPermissions {
  DefaultOnboardingPermissions({
    required NotificationService notificationService,
    required Future<bool> Function() requestBluetoothAccess,
    stt.SpeechToText? speech,
  })  : _notificationService = notificationService,
        _requestBluetoothAccess = requestBluetoothAccess,
        _speech = speech ?? stt.SpeechToText();

  final NotificationService _notificationService;
  final Future<bool> Function() _requestBluetoothAccess;
  final stt.SpeechToText _speech;
  bool _disposed = false;

  @override
  String get backgroundCapabilityExplanation =>
      'Background Bluetooth keeps Echo connected while the screen is off. '
      'Your phone may still pause work when the operating system requires it.';

  @override
  Future<bool> requestBluetooth() {
    if (_disposed) return Future.value(false);
    return _requestBluetoothAccess();
  }

  @override
  Future<bool> requestNotifications() {
    if (_disposed) return Future.value(false);
    return _notificationService.requestPermission();
  }

  @override
  Future<bool> requestVoiceMicrophone() async {
    if (_disposed) return false;
    return _speech.initialize();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_speech.cancel());
  }
}