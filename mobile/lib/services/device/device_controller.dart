import 'dart:async';

import '../../models/device_status.dart';
import 'device_ble_port.dart';
import 'device_identity_store.dart';
import 'device_protocol.dart';

typedef DeviceRetrySchedule = DeviceRetryHandle Function(
  Duration delay,
  void Function() callback,
);

abstract interface class DeviceRetryHandle {
  void cancel();
}

final class DeviceController {
  DeviceController({
    required DeviceBlePort ble,
    required DeviceIdentityStorePort identityStore,
    DeviceRetrySchedule? scheduleRetry,
  })  : _ble = ble,
        _identityStore = identityStore,
        _scheduleRetry = scheduleRetry ?? _scheduleTimer;

  static const _retryDelays = <Duration>[
    Duration.zero,
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  final DeviceBlePort _ble;
  final DeviceIdentityStorePort _identityStore;
  final DeviceRetrySchedule _scheduleRetry;
  final _stateController = StreamController<DeviceStatus>.broadcast();

  StreamSubscription<DeviceAdapterState>? _adapterSubscription;
  StreamSubscription<DeviceBlePhase>? _phaseSubscription;
  StreamSubscription<DeviceTelemetry>? _telemetrySubscription;
  StreamSubscription<DeviceInfo>? _infoSubscription;
  DeviceRetryHandle? _retry;
  String? _remoteId;
  DeviceTelemetry? _telemetry;
  DeviceInfo? _info;
  int _retryIndex = 0;
  int _generation = 0;
  bool _started = false;
  bool _ready = false;
  bool _pairing = false;
  bool _forgetting = false;
  bool _connectionAttemptInFlight = false;
  bool _resumeAfterAttempt = false;
  bool _disposed = false;

  DeviceStatus _state = const DeviceStatus(
    connectionState: DeviceConnectionState.unpaired,
  );
  DeviceStatus get state => _state;
  Stream<DeviceStatus> get stateStream => _stateController.stream;

  Future<void> start() async {
    if (_disposed || _started) return;
    _started = true;
    _adapterSubscription = _ble.adapterStateStream.listen(_onAdapterState);
    _phaseSubscription = _ble.phaseStream.listen(_onPhase);
    _telemetrySubscription = _ble.telemetryStream.listen(_onTelemetry);
    _infoSubscription = _ble.deviceInfoStream.listen(_onDeviceInfo);

    final generation = _generation;
    final remoteId = await _identityStore.loadRemoteId();
    if (_disposed || generation != _generation) return;
    _remoteId = remoteId;
    if (remoteId == null || remoteId.isEmpty) {
      _setConnectionState(DeviceConnectionState.unpaired);
      return;
    }
    if (_ble.adapterState != DeviceAdapterState.on) {
      _setConnectionState(DeviceConnectionState.bluetoothOff);
      return;
    }
    _beginReconnectCycle();
  }

  Future<void> pair() async {
    _ensureActive();
    if (_pairing) throw StateError('Pairing already in progress');
    if (_ble.adapterState != DeviceAdapterState.on) {
      _setConnectionState(DeviceConnectionState.bluetoothOff);
      throw StateError('Bluetooth is unavailable');
    }

    _cancelRetry();
    final generation = ++_generation;
    _pairing = true;
    _ready = false;
    _setConnectionState(DeviceConnectionState.scanning);
    try {
      final remoteId = await _ble.pair();
      if (!_isCurrent(generation)) return;
      await _identityStore.saveRemoteId(remoteId);
      if (!_isCurrent(generation)) return;
      _remoteId = remoteId;
      _ready = true;
      _retryIndex = 0;
      _setConnectedState();
    } catch (error) {
      if (_isCurrent(generation)) _setError(error);
      rethrow;
    } finally {
      _pairing = false;
    }
  }

  Future<void> setMuted(bool muted) async {
    _ensureActive();
    await _ble.setMuted(muted);
  }

  Future<void> forget() async {
    _ensureActive();
    if (_remoteId == null) {
      _setConnectionState(DeviceConnectionState.unpaired);
      return;
    }

    _forgetting = true;
    _ready = false;
    _cancelRetry();
    final generation = ++_generation;
    try {
      await _ble.forgetBond();
      if (!_isCurrent(generation)) return;
      await _identityStore.clear();
      if (!_isCurrent(generation)) return;
      _remoteId = null;
      _telemetry = null;
      _info = null;
      _retryIndex = 0;
      _setState(const DeviceStatus(
        connectionState: DeviceConnectionState.unpaired,
      ));
    } catch (error) {
      if (_isCurrent(generation)) _setError(error);
      rethrow;
    } finally {
      _forgetting = false;
    }
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    cancelReconnect();
    await _ble.disconnect();
  }

  Future<void> reconnect() {
    _ensureActive();
    if (_remoteId == null) {
      _setConnectionState(DeviceConnectionState.unpaired);
      return Future.value();
    }
    if (_ble.adapterState != DeviceAdapterState.on) {
      _setConnectionState(DeviceConnectionState.bluetoothOff);
      return Future.value();
    }
    _cancelRetry();
    _beginReconnectCycle();
    return Future.value();
  }

  void cancelReconnect() {
    if (_disposed) return;
    _generation++;
    _ready = false;
    _resumeAfterAttempt = false;
    _cancelRetry();
    if (_connectionAttemptInFlight) unawaited(_ble.disconnect());
    _setConnectionState(
      _remoteId == null
          ? DeviceConnectionState.unpaired
          : DeviceConnectionState.offline,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelRetry();
    await _adapterSubscription?.cancel();
    await _phaseSubscription?.cancel();
    await _telemetrySubscription?.cancel();
    await _infoSubscription?.cancel();
    await _ble.dispose();
    await _stateController.close();
  }

  void _onAdapterState(DeviceAdapterState adapterState) {
    if (_disposed) return;
    if (adapterState != DeviceAdapterState.on) {
      _generation++;
      _ready = false;
      _cancelRetry();
      if (_connectionAttemptInFlight) {
        _resumeAfterAttempt = true;
        unawaited(_ble.disconnect());
      }
      _setConnectionState(DeviceConnectionState.bluetoothOff);
      return;
    }
    if (_connectionAttemptInFlight) {
      _resumeAfterAttempt = true;
      return;
    }
    if (_remoteId != null &&
        !_ready &&
        !_pairing &&
        !_forgetting &&
        !_connectionAttemptInFlight &&
        _retry == null) {
      _beginReconnectCycle();
    }
  }

  void _onPhase(DeviceBlePhase phase) {
    if (_disposed) return;
    switch (phase) {
      case DeviceBlePhase.disconnected:
        if (_forgetting || _connectionAttemptInFlight) return;
        if (_ready && _remoteId != null) {
          _ready = false;
          _beginReconnectCycle();
        }
      case DeviceBlePhase.scanning:
        if (_pairing) _setConnectionState(DeviceConnectionState.scanning);
      case DeviceBlePhase.connecting:
        if (_pairing) _setConnectionState(DeviceConnectionState.connecting);
      case DeviceBlePhase.bonding:
        if (_pairing) _setConnectionState(DeviceConnectionState.bonding);
      case DeviceBlePhase.ready:
        _ready = true;
        _retryIndex = 0;
        _cancelRetry();
        _setConnectedState();
    }
  }

  void _onTelemetry(DeviceTelemetry telemetry) {
    if (_disposed) return;
    _telemetry = telemetry;
    if (_remoteId == null) return;
    _ready = true;
    _retryIndex = 0;
    _cancelRetry();
    _setConnectedState();
  }

  void _onDeviceInfo(DeviceInfo info) {
    if (_disposed) return;
    _info = info;
    if (_remoteId != null && _ready) _setConnectedState();
  }

  void _beginReconnectCycle() {
    if (_disposed ||
        _remoteId == null ||
        _forgetting ||
        _pairing ||
        _connectionAttemptInFlight ||
        _retry != null) {
      return;
    }
    _resumeAfterAttempt = false;
    _generation++;
    _ready = false;
    _connectionAttemptInFlight = false;
    _retryIndex = 0;
    _cancelRetry();
    _setConnectionState(DeviceConnectionState.reconnecting);
    _scheduleReconnect(_generation);
  }

  void _scheduleReconnect(int generation) {
    if (!_isCurrent(generation) || _remoteId == null || _retry != null) return;
    if (_ble.adapterState != DeviceAdapterState.on) {
      _setConnectionState(DeviceConnectionState.bluetoothOff);
      return;
    }
    final delayIndex = _retryIndex.clamp(0, _retryDelays.length - 1).toInt();
    final delay = _retryDelays[delayIndex];
    if (_retryIndex < _retryDelays.length - 1) _retryIndex++;
    _retry = _scheduleRetry(delay, () {
      _retry = null;
      if (!_isCurrent(generation)) return;
      unawaited(_attemptReconnect(generation, delayIndex));
    });
  }

  Future<void> _attemptReconnect(int generation, int delayIndex) async {
    if (!_isCurrent(generation) || _connectionAttemptInFlight) return;
    final remoteId = _remoteId;
    if (remoteId == null) return;
    _connectionAttemptInFlight = true;
    try {
      await _ble.connectSaved(remoteId);
      if (!_isCurrent(generation)) return;
      _ready = true;
      _retryIndex = 0;
      _setConnectedState();
    } catch (error) {
      if (!_isCurrent(generation)) return;
      if (delayIndex == _retryDelays.length - 1) {
        _setConnectionState(DeviceConnectionState.offline);
      } else {
        _setConnectionState(DeviceConnectionState.reconnecting);
      }
      _scheduleReconnect(generation);
    } finally {
      _connectionAttemptInFlight = false;
      if (!_disposed &&
          _resumeAfterAttempt &&
          _ble.adapterState == DeviceAdapterState.on &&
          _remoteId != null) {
        _resumeAfterAttempt = false;
        _beginReconnectCycle();
      }
    }
  }

  void _setConnectedState() {
    final telemetry = _telemetry;
    final info = _info;
    if (telemetry == null) {
      _setState(_state.copyWith(
        connectionState: DeviceConnectionState.listening,
        protocolVersion: info?.protocolVersion,
        firmwareVersion: info == null
            ? null
            : '${info.firmwareMajor}.${info.firmwareMinor}.${info.firmwarePatch}',
        error: null,
      ));
      return;
    }
    _setState(DeviceStatus(
      connectionState: telemetry.muted
          ? DeviceConnectionState.muted
          : DeviceConnectionState.listening,
      batteryPercent: telemetry.batteryPercent,
        protocolVersion: info?.protocolVersion,
        firmwareVersion: info == null
          ? null
          : '${info.firmwareMajor}.${info.firmwareMinor}.${info.firmwarePatch}',
      bufferCount: telemetry.bufferCount,
      bufferBytes: telemetry.bufferBytes,
      droppedSegments: telemetry.droppedSegments,
      overflowed: telemetry.overflowed,
    ));
  }

  void _setConnectionState(DeviceConnectionState connectionState) {
    _setState(_state.copyWith(connectionState: connectionState, error: null));
  }

  void _setError(Object error) {
    _setState(_state.copyWith(
      connectionState: DeviceConnectionState.error,
      error: error.toString(),
    ));
  }

  void _setState(DeviceStatus state) {
    if (_disposed || state == _state) return;
    _state = state;
    _stateController.add(state);
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _generation;

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('DeviceController is disposed');
  }

  static DeviceRetryHandle _scheduleTimer(
    Duration delay,
    void Function() callback,
  ) {
    return _TimerRetryHandle(Timer(delay, callback));
  }
}

final class _TimerRetryHandle implements DeviceRetryHandle {
  _TimerRetryHandle(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}