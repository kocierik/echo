import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/photo.dart';
import 'api_service.dart';

/// The wearable as the photo flow sees it.
abstract interface class PhotoDevice {
  /// Connected, with protocol 3 and a camera.
  bool get cameraReady;

  /// Connected at all (to tell "no camera" from "not connected").
  bool get connected;

  bool get muted;

  Future<void> sendTakePhoto();
}

/// Takes a photo from the app (the camera button in Ask).
abstract interface class PhotoTaker {
  /// Asks the backend for a photo and the wearable to take it. Throws
  /// [PhotoUnavailableException] when the wearable cannot take one now.
  Future<PhotoInfo> takePhoto({String? question, String? chatSessionId});

  /// Waits until the photo is answered or failed (polling the backend).
  Future<PhotoInfo> waitForAnswer(String photoId);
}

final class PhotoUnavailableException implements Exception {
  const PhotoUnavailableException(this.reason);

  /// "not_connected", "no_camera", "muted" or "busy".
  final String reason;

  String get message => switch (reason) {
        'muted' => 'Echo is muted: unmute it to take a photo.',
        'no_camera' =>
          'This wearable has no camera, or its firmware needs an update.',
        'busy' => 'The wearable is still taking the previous photo.',
        _ => 'Connect the wearable to take a photo.',
      };

  @override
  String toString() => 'PhotoUnavailableException: $reason';
}

/// Photos from the wearable camera, between the backend and the wearable.
///
/// - A voice request ("Echo, what is this?") reaches the app as a TAKE_PHOTO command
///   from `GET /device/commands`, long-polled while the app runs; the app button calls
///   [takePhoto]. Either way the wearable gets TAKE_PHOTO, one photo at a time.
/// - The JPEG arrives over BLE ([uploadFromDevice]); once the backend has it the
///   wearable is told to free it (UPLOAD_OK, sent by the relay). Photos are uploaded
///   on any network: the user asked for them and is waiting.
/// - When the wearable cannot take it (PHOTO_FAILED, not connected, muted), the
///   backend is told why and says so in the chat.
final class PhotoService implements PhotoTaker {
  PhotoService({
    required PhotoApi api,
    required PhotoDevice device,
    this.commandWait = const Duration(seconds: 20),
    this.captureTimeout = const Duration(seconds: 60),
    this.answerTimeout = const Duration(seconds: 90),
    this.pollInterval = const Duration(seconds: 2),
    Future<void> Function(Duration)? sleep,
  })  : _api = api,
        _device = device,
        _sleep = sleep ?? Future<void>.delayed;

  static const _retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  final PhotoApi _api;
  final PhotoDevice _device;
  final Future<void> Function(Duration) _sleep;
  final Duration commandWait;
  final Duration captureTimeout;
  final Duration answerTimeout;
  final Duration pollInterval;

  String? _pendingId;
  Timer? _pendingTimer;
  bool _running = false;
  int _loopGeneration = 0;

  /// The photo the wearable is taking or sending, if any.
  @visibleForTesting
  String? get pendingPhotoId => _pendingId;

  /// Long-polls the wearable's commands until [stop].
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_commandLoop(++_loopGeneration));
  }

  void stop() {
    _running = false;
    _loopGeneration++;
    _clearPending();
  }

  @override
  Future<PhotoInfo> takePhoto({String? question, String? chatSessionId}) async {
    final reason = _unavailableReason() ?? (_pendingId != null ? 'busy' : null);
    if (reason != null) throw PhotoUnavailableException(reason);
    final photo = await _api.requestPhoto(
      question: question,
      chatSessionId: chatSessionId,
    );
    await _trigger(photo.id);
    return photo;
  }

  @override
  Future<PhotoInfo> waitForAnswer(String photoId) async {
    final deadline = DateTime.now().add(answerTimeout);
    while (true) {
      final photo = await _api.getPhoto(photoId);
      if (photo.isFinished || DateTime.now().isAfter(deadline)) return photo;
      await _sleep(pollInterval);
    }
  }

  /// A JPEG from the wearable. True once the backend has it (the wearable then
  /// frees it); throws to have the relay retry.
  Future<bool> uploadFromDevice(Uint8List jpeg, DateTime capturedAt) async {
    var photoId = _pendingId;
    if (photoId == null) {
      // A photo kept by the wearable across an app restart, or past the timeout:
      // still delivered, as a photo without a question
      photoId = (await _api.requestPhoto()).id;
      _pendingId = photoId;
    }
    await _api.uploadPhoto(photoId, jpeg, capturedAt);
    if (_pendingId == photoId) _clearPending();
    return true;
  }

  /// PHOTO_FAILED from the wearable.
  Future<void> onDeviceFailure(String reason) async {
    final photoId = _pendingId;
    if (photoId == null) return;
    _clearPending();
    await _report(photoId, reason);
  }

  Future<void> _commandLoop(int generation) async {
    var failures = 0;
    while (_running && generation == _loopGeneration) {
      try {
        final commands = await _api.getDeviceCommands(wait: commandWait);
        failures = 0;
        for (final command in commands) {
          if (generation != _loopGeneration) return;
          if (command.type == 'take_photo') await _onTakePhoto(command.photoId);
        }
      } catch (error) {
        // Offline, suspended in the background, server restarting: back off
        if (generation != _loopGeneration) return;
        final delay = _retryDelays[failures.clamp(0, _retryDelays.length - 1)];
        failures++;
        debugPrint('[Photos] command poll failed: $error; retrying in $delay');
        await _sleep(delay);
      }
    }
  }

  Future<void> _onTakePhoto(String photoId) async {
    final reason = _unavailableReason() ?? (_pendingId != null ? 'busy' : null);
    if (reason != null) {
      await _report(photoId, reason);
      return;
    }
    await _trigger(photoId);
  }

  Future<void> _trigger(String photoId) async {
    _pendingId = photoId;
    _pendingTimer?.cancel();
    // Never stuck: a photo that never comes frees the slot (the backend times out too)
    _pendingTimer = Timer(captureTimeout, () {
      if (_pendingId == photoId) _pendingId = null;
    });
    try {
      await _device.sendTakePhoto();
    } catch (_) {
      if (_pendingId == photoId) _clearPending();
      await _report(photoId, 'not_connected');
    }
  }

  String? _unavailableReason() {
    if (!_device.connected) return 'not_connected';
    if (_device.muted) return 'muted';
    if (!_device.cameraReady) return 'no_camera';
    return null;
  }

  Future<void> _report(String photoId, String reason) async {
    try {
      await _api.reportPhotoFailure(photoId, reason);
    } catch (error) {
      // The backend times the request out and tells the user anyway
      debugPrint('[Photos] could not report $reason for $photoId: $error');
    }
  }

  void _clearPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingId = null;
  }
}
