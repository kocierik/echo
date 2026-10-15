import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/device_command.dart';
import '../api/device_api.dart';

/// Long-polls the server's commands while the app runs (the wearable keeps it awake
/// through the day) and hands each to its handler: TAKE_PHOTO to the wearable
/// (PhotoService), Reminders and Calendar to this iPhone (PhoneActionsService).
final class DeviceCommandLoop {
  DeviceCommandLoop({
    required DeviceCommandsApi api,
    required Future<void> Function(TakePhotoCommand command) onTakePhoto,
    required Future<void> Function(PhoneActionCommand command) onPhoneAction,
    this.wait = const Duration(seconds: 20),
    Future<void> Function(Duration)? sleep,
  })  : _api = api,
        _onTakePhoto = onTakePhoto,
        _onPhoneAction = onPhoneAction,
        _sleep = sleep ?? Future<void>.delayed;

  static const _retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  final DeviceCommandsApi _api;
  final Future<void> Function(TakePhotoCommand) _onTakePhoto;
  final Future<void> Function(PhoneActionCommand) _onPhoneAction;
  final Future<void> Function(Duration) _sleep;
  final Duration wait;
  bool _running = false;
  int _generation = 0;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop(++_generation));
  }

  void stop() {
    _running = false;
    _generation++;
  }

  Future<void> _loop(int generation) async {
    var failures = 0;
    while (_running && generation == _generation) {
      try {
        final commands = await _api.getDeviceCommands(wait: wait);
        failures = 0;
        for (final command in commands) {
          if (generation != _generation) return;
          switch (command) {
            case TakePhotoCommand():
              await _onTakePhoto(command);
            case PhoneActionCommand():
              // Not awaited: a slow one must not hold up the next commands
              unawaited(_onPhoneAction(command));
          }
        }
      } catch (error) {
        // Offline, suspended in the background, server restarting: back off
        if (generation != _generation) return;
        final delay = _retryDelays[failures.clamp(0, _retryDelays.length - 1)];
        failures++;
        debugPrint('[Commands] poll failed: $error; retrying in $delay');
        await _sleep(delay);
      }
    }
  }
}
