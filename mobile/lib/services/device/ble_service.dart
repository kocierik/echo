import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../api/api_service.dart';
import 'ble_packet_assembler.dart';
import 'ble_relay_controller.dart';
import 'device_ble_port.dart';
import 'device_protocol.dart';
import '../app/network_policy.dart';
import 'firmware_update.dart';
import 'photo_service.dart';

class EchoBleUuids {
  static const serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const audioCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
  static const controlCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a9';
  // Protocol 4: firmware updates, [offset u32, bytes] written with response
  static const otaCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26aa';
}

enum BleConnectionState { disconnected, scanning, connecting, connected }

enum BleMessageKind { phase, progress, error, completion }

class BleUiMessage {
  const BleUiMessage(this.text, this.kind);

  final String text;
  final BleMessageKind kind;

  bool get isError => kind == BleMessageKind.error;
  bool get isCompletion => kind == BleMessageKind.completion;

  int get priority => switch (kind) {
        BleMessageKind.progress => 0,
        BleMessageKind.phase => 1,
        BleMessageKind.error || BleMessageKind.completion => 2,
      };
}

class BleService implements DeviceBlePort, PhotoDevice, FirmwareLink {
  BleService({
    ApiService? api,
    NetworkAccess? networkAccess,
    NetworkPolicy? networkPolicy,
  })  : _api = api ?? ApiService(),
        _networkAccess = networkAccess ?? ConnectivityNetworkAccess(),
        _networkPolicy = networkPolicy ?? NetworkPolicy() {
    _relay = BleRelayController(
      upload: _uploadSegment,
      writeControl: _writeControl,
      onStatus: (message, {required isError}) {
        final isCompletion = !isError && message.endsWith(' uploaded');
        _publishMessage(
          message,
          isError
              ? BleMessageKind.error
              : isCompletion
                  ? BleMessageKind.completion
                  : BleMessageKind.phase,
        );
      },
      onUploaded: (segmentId) {
        _consecutiveUploadFailures = 0;
        _segmentUploadedController.add(segmentId);
      },
    );
  }

  static const _messageInterval = Duration(milliseconds: 250);
  static const _scanDuration = Duration(seconds: 10);
  static const _connectionTimeout = Duration(seconds: 35);
  static const _forgetTimeout = Duration(seconds: 8);

  final ApiService _api;
  final NetworkAccess _networkAccess;
  final NetworkPolicy _networkPolicy;
  final BlePacketAssembler _assembler = BlePacketAssembler();
  late final BleRelayController _relay;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _audioChar;
  BluetoothCharacteristic? _controlChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<List<int>>? _controlSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  Completer<BluetoothDevice>? _scanCompleter;
  Completer<void>? _pendingConnection;
  Completer<void>? _forgetAck;
  Completer<void>? _forgetDisconnected;
  Future<void>? _cleanupInFlight;
  Timer? _messageTimer;
  BleUiMessage? _pendingMessage;
  DateTime? _lastMessageAt;
  bool _mtuFailureLogged = false;
  bool _disposed = false;
  int _connectionGeneration = 0;
  int _consecutiveUploadFailures = 0;
  DeviceTelemetry? _lastTelemetry;

  /// Uploads a photo from the wearable (set by the app's photo service).
  Future<bool> Function(Uint8List jpeg, DateTime capturedAt)? photoUploader;

  /// A photo started arriving (its segment id): it was just taken.
  void Function(int segmentId)? onPhotoStarted;

  /// The wearable could not take a photo (PHOTO_FAILED reason).
  Future<void> Function(String reason)? onPhotoFailed;

  @override
  bool get connected => _phase == DeviceBlePhase.ready;

  @override
  bool get cameraReady => connected && (_lastTelemetry?.cameraAvailable ?? false);

  @override
  bool get muted => _lastTelemetry?.muted ?? false;

  @override
  Future<void> sendTakePhoto() => _writeControl(DeviceProtocol.takePhoto());

  BluetoothCharacteristic? _otaChar;
  final _otaStatusController = StreamController<OtaStatus>.broadcast();

  @override
  bool get canUpdateFirmware => connected && _otaChar != null;

  /// One write with response carries MTU - 3 bytes; 4 of them are the offset.
  @override
  int get firmwareChunkSize {
    final mtu = _device?.mtuNow ?? 23;
    final value =
        (mtu > 515 ? 515 : mtu) - 3 - DeviceProtocol.otaDataHeaderSize;
    return value < 16 ? 16 : value;
  }

  @override
  Stream<OtaStatus> get otaStatusStream => _otaStatusController.stream;

  @override
  Future<void> beginFirmwareUpdate(
          int size, List<int> sha256, List<int>? signature) =>
      _writeControl(DeviceProtocol.otaBegin(size, sha256, signature: signature));

  @override
  Future<void> writeFirmwareChunk(int offset, List<int> bytes) async {
    final characteristic = _otaChar;
    if (characteristic == null) {
      throw StateError('Firmware updates unavailable');
    }
    // With response: the wearable has written the chunk to flash when this returns
    await characteristic.write(
      DeviceProtocol.otaChunk(offset, bytes),
      withoutResponse: false,
      timeout: 15,
    );
  }

  @override
  Future<void> abortFirmwareUpdate() =>
      _writeControl(DeviceProtocol.otaAbort());

  BleConnectionState _state = BleConnectionState.disconnected;
  BleConnectionState get state => _state;

  final _stateController = StreamController<BleConnectionState>.broadcast();
  Stream<BleConnectionState> get stateStream => _stateController.stream;

  DeviceBlePhase _phase = DeviceBlePhase.disconnected;

  @override
  DeviceBlePhase get phase => _phase;

  final _phaseController = StreamController<DeviceBlePhase>.broadcast();

  @override
  Stream<DeviceBlePhase> get phaseStream => _phaseController.stream;

  @override
  DeviceAdapterState get adapterState =>
      _mapAdapterState(FlutterBluePlus.adapterStateNow);

  @override
  Stream<DeviceAdapterState> get adapterStateStream =>
      FlutterBluePlus.adapterState.map(_mapAdapterState);

  final _telemetryController = StreamController<DeviceTelemetry>.broadcast();

  @override
  Stream<DeviceTelemetry> get telemetryStream => _telemetryController.stream;

  final _deviceInfoController = StreamController<DeviceInfo>.broadcast();

  @override
  Stream<DeviceInfo> get deviceInfoStream => _deviceInfoController.stream;

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messageStream => _messageController.stream;

  final _uiMessageController = StreamController<BleUiMessage>.broadcast();
  Stream<BleUiMessage> get uiMessageStream => _uiMessageController.stream;

  final _segmentUploadedController = StreamController<int>.broadcast();
  Stream<int> get segmentUploadedStream => _segmentUploadedController.stream;

  final _uploadFailureController = StreamController<int>.broadcast();
  Stream<int> get uploadFailureStream => _uploadFailureController.stream;

  final List<String> _messages = [];
  List<String> get messages => List.unmodifiable(_messages);

  Future<void> startScan() async {
    if (_disposed || _scanCompleter != null) return;
    try {
      final device = await _scanForEcho();
      await _connectDevice(device, pairing: true, autoConnect: false);
    } catch (error) {
      _publishMessage('BLE scan failed: $error', BleMessageKind.error);
      await _cleanupConnection();
    }
  }

  @override
  Future<String> pair() async {
    if (_disposed) throw StateError('BleService is disposed');
    try {
      final device = await _scanForEcho();
      await _connectDevice(device, pairing: true, autoConnect: false);
      return device.remoteId.str;
    } catch (error) {
      _publishMessage('BLE pairing failed: $error', BleMessageKind.error);
      await _cleanupConnection();
      rethrow;
    }
  }

  @override
  Future<void> connectSaved(String remoteId) async {
    if (_disposed) throw StateError('BleService is disposed');
    final currentDevice = _device;
    if (_phase == DeviceBlePhase.ready &&
        currentDevice?.remoteId.str == remoteId) {
      return;
    }
    await _connectDevice(
      BluetoothDevice.fromId(remoteId),
      pairing: false,
      autoConnect: true,
    );
  }

  Future<BluetoothDevice> _scanForEcho() async {
    if (_scanCompleter != null) {
      throw StateError('BLE scan already in progress');
    }
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      throw StateError('Bluetooth is unavailable');
    }

    await _cancelScan();
    _setPhase(DeviceBlePhase.scanning);
    final completer = Completer<BluetoothDevice>();
    _scanCompleter = completer;
    _scanSub = FlutterBluePlus.scanResults.listen(
      _onScanResults,
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    try {
      await FlutterBluePlus.startScan(timeout: _scanDuration);
      return await completer.future.timeout(
        _scanDuration,
        onTimeout: () => throw TimeoutException('Echo device not found'),
      );
    } finally {
      if (identical(_scanCompleter, completer)) _scanCompleter = null;
      await _cancelScan();
    }
  }

  void _onScanResults(List<ScanResult> results) {
    final completer = _scanCompleter;
    if (completer == null || completer.isCompleted) return;
    for (final result in results) {
      final advertisedServices = result.advertisementData.serviceUuids
          .map((uuid) => uuid.toString().toLowerCase());
      final deviceName = result.device.platformName.toLowerCase();
      final advertisedName = result.advertisementData.advName.toLowerCase();
      final matchesService = advertisedServices.any(
        (uuid) => uuid.contains(EchoBleUuids.serviceUuid),
      );
        if (matchesService ||
          deviceName.contains('echo') ||
          advertisedName.contains('echo')) {
        completer.complete(result.device);
        return;
      }
    }
  }

  Future<void> _connectDevice(
    BluetoothDevice device, {
    required bool pairing,
    required bool autoConnect,
  }) async {
    await _cancelScan();
    final previousDevice = _device;
    if (previousDevice != null && previousDevice != device) {
      try {
        await previousDevice.disconnect();
      } catch (_) {}
    }
    await _cleanupConnection(emitDisconnected: false);
    final generation = ++_connectionGeneration;
    _device = device;
    _setPhase(DeviceBlePhase.connecting);
    final connected = Completer<void>();
    _pendingConnection = connected;
    Object? connectionError;
    StackTrace? connectionStackTrace;
    var wasConnected = device.isConnected;
    if (wasConnected) connected.complete();
    _connectionSub = device.connectionState.listen(
      (connectionState) {
        if (_disposed || generation != _connectionGeneration) return;
        if (connectionState == BluetoothConnectionState.connected) {
          wasConnected = true;
          if (!connected.isCompleted) connected.complete();
          return;
        }
        if (!wasConnected) return;
        if (!connected.isCompleted) {
          connectionError = StateError('BLE device disconnected');
          connected.complete();
        }
        final forgotten = _forgetDisconnected;
        if (_forgetAck?.isCompleted == true &&
            forgotten != null &&
            !forgotten.isCompleted) {
          forgotten.complete();
        }
        unawaited(_cleanupConnection(expectedGeneration: generation));
      },
      onError: (Object error, StackTrace stackTrace) {
        connectionError = error;
        connectionStackTrace = stackTrace;
        if (!connected.isCompleted) {
          connected.complete();
        }
      },
    );

    try {
      debugPrint(
        '[BLE] connecting to ${device.platformName} (${device.remoteId})',
      );
      if (autoConnect) {
        await device.connect(
          license: License.nonprofit,
          autoConnect: true,
          mtu: null,
        );
      } else {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 8),
          mtu: null,
        );
      }
      if (device.isConnected && !connected.isCompleted) connected.complete();
      await connected.future.timeout(_connectionTimeout);
      if (identical(_pendingConnection, connected)) _pendingConnection = null;
      final error = connectionError;
      if (error != null) {
        Error.throwWithStackTrace(
          error,
          connectionStackTrace ?? StackTrace.current,
        );
      }
      if (_disposed || generation != _connectionGeneration) {
        throw StateError('BLE connection was cancelled');
      }

      if (Platform.isAndroid) {
        try {
          final mtu = await device.requestMtu(247);
          debugPrint('[BLE] negotiated MTU $mtu');
        } catch (error) {
          if (!_mtuFailureLogged) {
            _mtuFailureLogged = true;
            debugPrint('[BLE] MTU request failed: $error');
            _publishMessage('MTU request failed: $error', BleMessageKind.error);
          }
        }
      }

      if (pairing) _setPhase(DeviceBlePhase.bonding);
      final services = await device.discoverServices();
      final echoService = services.firstWhere(
        (service) => service.uuid == Guid(EchoBleUuids.serviceUuid),
        orElse: () => throw StateError('Echo service not found'),
      );
      _audioChar = echoService.characteristics.firstWhere(
        (characteristic) =>
            characteristic.uuid == Guid(EchoBleUuids.audioCharUuid),
        orElse: () => throw StateError('Audio characteristic not found'),
      );
      _controlChar = echoService.characteristics.firstWhere(
        (characteristic) =>
            characteristic.uuid == Guid(EchoBleUuids.controlCharUuid),
        orElse: () => throw StateError('Control characteristic not found'),
      );
      // Absent before protocol 4: no updates over Bluetooth
      _otaChar = echoService.characteristics
          .where((c) => c.uuid == Guid(EchoBleUuids.otaCharUuid))
          .firstOrNull;

      _audioSub = _audioChar!.onValueReceived.listen(
        (value) => unawaited(_onAudioPacket(value)),
        onError: (Object error) => _publishMessage(
          'Audio notification failed: $error',
          BleMessageKind.error,
        ),
      );
      _controlSub = _controlChar!.onValueReceived.listen(
        _onControlPacket,
        onError: (Object error) => _publishMessage(
          'Control notification failed: $error',
          BleMessageKind.error,
        ),
      );
      await _audioChar!.setNotifyValue(true);
      await _controlChar!.setNotifyValue(true);

      _relay.setConnected(true);
      await _relay.sendControl(_buildSetTime());
      await _relay.sendControl(const [0x10]);

      if (_disposed || generation != _connectionGeneration) {
        throw StateError('BLE connection was cancelled');
      }
      _setPhase(DeviceBlePhase.ready);
      _publishMessage('Echo device connected', BleMessageKind.phase);
    } catch (error) {
      if (identical(_pendingConnection, connected)) {
        _pendingConnection = null;
      }
      debugPrint('[BLE] connection failed: $error');
      _publishMessage('BLE connection failed: $error', BleMessageKind.error);
      try {
        await device.disconnect();
      } catch (_) {}
      await _cleanupConnection(expectedGeneration: generation);
      rethrow;
    }
  }

  Future<void> _onAudioPacket(List<int> value) async {
    final events = _assembler.add(value);
    for (final event in events) {
      switch (event) {
        case BleSegmentStarted():
          if (event.isPhoto) onPhotoStarted?.call(event.segmentId);
          _publishMessage(
            event.isPhoto
                ? 'Receiving photo ${event.segmentId}'
                : 'Receiving segment ${event.segmentId}',
            BleMessageKind.phase,
          );
        case BleTransferProgress():
          final percent = event.totalBytes == 0
              ? 0
              : (event.receivedBytes * 100 ~/ event.totalBytes);
          _publishMessage(
            'Receiving segment ${event.segmentId}: $percent%',
            BleMessageKind.progress,
          );
        case BleSegmentCompleted():
          _publishMessage(
            'BLE transfer complete for segment ${event.segment.id}',
            BleMessageKind.phase,
          );
        case BleRestartRequired():
        case BleAckRequired():
          break;
      }
    }

    try {
      await _relay.handleEvents(events);
    } catch (error) {
      _publishMessage('BLE control failed: $error', BleMessageKind.error);
    }
  }

  void _onControlPacket(List<int> value) {
    if (value.isEmpty) return;
    if (DeviceProtocol.isForgetBondOk(value)) {
      final acknowledgement = _forgetAck;
      if (acknowledgement != null && !acknowledgement.isCompleted) {
        acknowledgement.complete();
      }
      return;
    }

    final otaStatus = DeviceProtocol.parseOtaStatus(value);
    if (otaStatus != null) {
      _otaStatusController.add(otaStatus);
      return;
    }

    final photoFailure = DeviceProtocol.parsePhotoFailed(value);
    if (photoFailure != null) {
      _publishMessage('Photo not taken: $photoFailure', BleMessageKind.error);
      final handler = onPhotoFailed;
      if (handler != null) unawaited(handler(photoFailure));
      return;
    }

    try {
      switch (value.first) {
        case 0x20:
          final telemetry = DeviceProtocol.parseStatus(Uint8List.fromList(value));
          _lastTelemetry = telemetry;
          _telemetryController.add(telemetry);
        case 0x21:
          _deviceInfoController.add(
            DeviceProtocol.parseInfo(Uint8List.fromList(value)),
          );
      }
    } on DeviceProtocolException catch (error) {
      _publishMessage(
        'Invalid wearable control packet: ${error.message}',
        BleMessageKind.error,
      );
    }
  }

  Future<bool> _uploadSegment(BleCompletedSegment segment) async {
    if (segment.isPhoto) return _uploadPhoto(segment);
    try {
      final networkTypes = await _networkAccess.currentTypes();
      if (!_networkPolicy.canUpload(networkTypes)) {
        _publishMessage(
          'Segment ${segment.id} upload deferred by network policy; retrying',
          BleMessageKind.error,
        );
        _recordUploadFailure();
        return false;
      }

      final uploaded = await _api.uploadSegment(
        audioData: segment.adpcmBytes,
        recordedAt: segment.recordedAt.toIso8601String(),
        durationMs: segment.durationMs,
        silenceBeforeMs: segment.silenceBeforeMs,
        audioEnergy: segment.averageEnergy,
      );
      if (!uploaded) _recordUploadFailure();
      return uploaded;
    } catch (_) {
      _recordUploadFailure();
      rethrow;
    }
  }

  /// Photos skip the Wi-Fi-only policy: the user asked for them and is waiting.
  Future<bool> _uploadPhoto(BleCompletedSegment segment) async {
    final upload = photoUploader;
    if (upload == null) return false;
    return upload(segment.jpegBytes, segment.recordedAt);
  }

  void _recordUploadFailure() {
    if (_disposed) return;
    _consecutiveUploadFailures++;
    _uploadFailureController.add(_consecutiveUploadFailures);
  }

  Future<void> _writeControl(List<int> value) async {
    final characteristic = _controlChar;
    if (characteristic == null) {
      throw StateError('Control characteristic unavailable');
    }
    await characteristic.write(value, withoutResponse: false);
  }

  @override
  Future<void> setMuted(bool muted) =>
      _writeControl(DeviceProtocol.setMuted(muted));

  @override
  Future<void> setMicGain(int gain) =>
      _writeControl(DeviceProtocol.setMicGain(gain));

  @override
  Future<void> forgetBond() async {
    if (_disposed) throw StateError('BleService is disposed');
    if (_phase != DeviceBlePhase.ready || _controlChar == null) {
      throw StateError('Echo device is not ready');
    }
    if (_forgetAck != null || _forgetDisconnected != null) {
      throw StateError('Forget bond already in progress');
    }

    final acknowledgement = Completer<void>();
    final disconnected = Completer<void>();
    _forgetAck = acknowledgement;
    _forgetDisconnected = disconnected;
    try {
      await _writeControl(DeviceProtocol.forgetBond());
      await acknowledgement.future.timeout(
        _forgetTimeout,
        onTimeout: () => throw TimeoutException(
          'Timed out waiting for forget-bond acknowledgement',
        ),
      );
      await disconnected.future.timeout(
        _forgetTimeout,
        onTimeout: () => throw TimeoutException(
          'Timed out waiting for wearable to disconnect after forget-bond acknowledgement',
        ),
      );
    } finally {
      if (identical(_forgetAck, acknowledgement)) _forgetAck = null;
      if (identical(_forgetDisconnected, disconnected)) {
        _forgetDisconnected = null;
      }
    }
  }

  Uint8List _buildSetTime() {
    final bytes = Uint8List(11);
    final data = ByteData.sublistView(bytes);
    final now = DateTime.now();
    data.setUint8(0, 0x14);
    data.setInt64(1, now.toUtc().millisecondsSinceEpoch, Endian.little);
    data.setInt16(9, now.timeZoneOffset.inMinutes, Endian.little);
    return bytes;
  }

  @override
  Future<void> disconnect() async {
    _relay.setConnected(false);
    final device = _device;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (error) {
        _publishMessage('BLE disconnect failed: $error', BleMessageKind.error);
      }
    }
    await _cleanupConnection();
  }

  Future<void> _cleanupConnection({
    int? expectedGeneration,
    bool emitDisconnected = true,
  }) async {
    if (expectedGeneration != null &&
        expectedGeneration != _connectionGeneration) {
      return;
    }
    final existingCleanup = _cleanupInFlight;
    if (existingCleanup != null) {
      await existingCleanup;
      return;
    }

    final cleanup = Completer<void>();
    _cleanupInFlight = cleanup.future;
    _connectionGeneration++;
    final cleanupGeneration = _connectionGeneration;
    _relay.setConnected(false);
    _assembler.reset();
    _lastTelemetry = null;
    final audioSub = _audioSub;
    final controlSub = _controlSub;
    final connectionSub = _connectionSub;
    final pendingConnection = _pendingConnection;
    _audioSub = null;
    _controlSub = null;
    _connectionSub = null;
    _pendingConnection = null;
    _device = null;
    _audioChar = null;
    _controlChar = null;
    _otaChar = null;
    if (pendingConnection != null && !pendingConnection.isCompleted) {
      pendingConnection.complete();
    }
    try {
      await audioSub?.cancel();
      await controlSub?.cancel();
      await connectionSub?.cancel();
      if (!_disposed &&
          emitDisconnected &&
          cleanupGeneration == _connectionGeneration) {
        _setPhase(DeviceBlePhase.disconnected);
      }
    } finally {
      cleanup.complete();
      if (identical(_cleanupInFlight, cleanup.future)) {
        _cleanupInFlight = null;
      }
    }
  }

  Future<void> _cancelScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
  }

  void _setPhase(DeviceBlePhase phase) {
    if (_disposed || _phase == phase) return;
    _phase = phase;
    _phaseController.add(phase);
    _setState(switch (phase) {
      DeviceBlePhase.disconnected => BleConnectionState.disconnected,
      DeviceBlePhase.scanning => BleConnectionState.scanning,
      DeviceBlePhase.connecting || DeviceBlePhase.bonding =>
          BleConnectionState.connecting,
      DeviceBlePhase.ready => BleConnectionState.connected,
    });
  }

  static DeviceAdapterState _mapAdapterState(BluetoothAdapterState state) {
    if (state == BluetoothAdapterState.on) return DeviceAdapterState.on;
    if (state == BluetoothAdapterState.off) return DeviceAdapterState.off;
    if (state == BluetoothAdapterState.unauthorized) {
      return DeviceAdapterState.unauthorized;
    }
    return DeviceAdapterState.unavailable;
  }

  void _setState(BleConnectionState state) {
    if (_disposed || _state == state) return;
    _state = state;
    _stateController.add(state);
  }

  void _publishMessage(String text, BleMessageKind kind) {
    if (_disposed) return;
    final incoming = BleUiMessage(text, kind);
    final pending = _pendingMessage;
    final message = pending == null || incoming.priority >= pending.priority
      ? incoming
      : pending;
    final now = DateTime.now();
    final elapsed = _lastMessageAt == null
        ? _messageInterval
        : now.difference(_lastMessageAt!);
    if (elapsed >= _messageInterval) {
      _messageTimer?.cancel();
      _messageTimer = null;
      _pendingMessage = null;
      _emitMessage(message);
      return;
    }

    _pendingMessage = message;
    _messageTimer ??= Timer(_messageInterval - elapsed, () {
      _messageTimer = null;
      final pending = _pendingMessage;
      _pendingMessage = null;
      if (pending != null) _emitMessage(pending);
    });
  }

  void _emitMessage(BleUiMessage message) {
    if (_disposed) return;
    _lastMessageAt = DateTime.now();
    _messages.insert(0, message.text);
    if (_messages.length > 500) _messages.removeLast();
    _messageController.add(message.text);
    _uiMessageController.add(message);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _connectionGeneration++;
    _messageTimer?.cancel();
    final pendingConnection = _pendingConnection;
    _pendingConnection = null;
    if (pendingConnection != null && !pendingConnection.isCompleted) {
      pendingConnection.complete();
    }
    final scanCompleter = _scanCompleter;
    if (scanCompleter != null && !scanCompleter.isCompleted) {
      scanCompleter.completeError(StateError('BleService is disposed'));
    }
    _scanCompleter = null;
    await _cancelScan();
    final device = _device;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    await _audioSub?.cancel();
    await _controlSub?.cancel();
    await _connectionSub?.cancel();
    _relay.dispose();
    _api.dispose();
    _assembler.reset();
    await _stateController.close();
    await _phaseController.close();
    await _telemetryController.close();
    await _deviceInfoController.close();
    await _otaStatusController.close();
    await _messageController.close();
    await _uiMessageController.close();
    await _segmentUploadedController.close();
    await _uploadFailureController.close();
  }
}

late BleService bleService;
