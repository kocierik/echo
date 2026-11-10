import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/device_status.dart';

/// What the Live Activity shows, from the wearable's status.
@immutable
final class LiveActivityState {
  const LiveActivityState({
    required this.status,
    required this.battery,
    required this.pendingMinutes,
  });

  /// "listening", "muted" or "offline"; null: no Live Activity (nothing paired, or Echo off).
  static LiveActivityState? from(DeviceStatus device) {
    final status = switch (device.connectionState) {
      DeviceConnectionState.unpaired || DeviceConnectionState.off => null,
      DeviceConnectionState.listening => 'listening',
      DeviceConnectionState.muted => 'muted',
      DeviceConnectionState.turningOff => 'muted',
      _ => 'offline',
    };
    if (status == null) return null;
    return LiveActivityState(
      status: status,
      battery: device.batteryPercent ?? -1,
      pendingMinutes: device.bufferBytes ~/ (8 * 1024 * 60),
    );
  }

  final String status;
  final int battery;
  final int pendingMinutes;

  Map<String, Object> toArguments() =>
      {'status': status, 'battery': battery, 'pendingMinutes': pendingMinutes};

  @override
  bool operator ==(Object other) =>
      other is LiveActivityState &&
      other.status == status &&
      other.battery == battery &&
      other.pendingMinutes == pendingMinutes;

  @override
  int get hashCode => Object.hash(status, battery, pendingMinutes);
}

/// The wearable on the Lock Screen and in the Dynamic Island (iOS 16.1+), through the
/// native "echo/live_activity" channel. On Android the same channel drives the foreground
/// service (EchoStatusService.kt) whose notification shows the same, and which keeps the
/// Bluetooth link alive in the background. Updated only when what it shows changes; ended
/// when nothing is paired or (iOS) the user turns it off. Without the channel every call
/// is a no-op.
final class LiveActivityService {
  LiveActivityService({
    required DeviceStatus initial,
    required Stream<DeviceStatus> statuses,
    required bool Function() enabled,
    MethodChannel channel = const MethodChannel('echo/live_activity'),
  })  : _current = initial,
        _statuses = statuses,
        _enabled = enabled,
        _channel = channel;

  final Stream<DeviceStatus> _statuses;
  final bool Function() _enabled;
  final MethodChannel _channel;
  DeviceStatus _current;
  StreamSubscription<DeviceStatus>? _subscription;
  LiveActivityState? _shown;

  void start() {
    _subscription ??= _statuses.listen((status) {
      _current = status;
      unawaited(refresh());
    });
    unawaited(refresh());
  }

  /// Shows the current status (or ends the activity); call after the setting changes.
  Future<void> refresh() async {
    final state = _enabled() ? LiveActivityState.from(_current) : null;
    if (state == _shown) return;
    try {
      if (state == null) {
        await _channel.invokeMethod<void>('end');
      } else {
        await _channel.invokeMethod<void>('update', state.toArguments());
      }
      _shown = state;
    } on MissingPluginException {
      // Not iOS, or an iOS without Live Activities
    } on PlatformException catch (error) {
      debugPrint('[LiveActivity] ${error.message}');
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
