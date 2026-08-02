import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'api_service.dart';
import 'ble_packet_assembler.dart';
import 'ble_relay_controller.dart';

class EchoBleUuids {
  static const serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const audioCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
  static const controlCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a9';
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

class BleService {
  BleService({ApiService? api}) : _api = api ?? ApiService() {
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
    );
  }

  static const _messageInterval = Duration(milliseconds: 250);

  final ApiService _api;
  final BlePacketAssembler _assembler = BlePacketAssembler();
  late final BleRelayController _relay;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _audioChar;
  BluetoothCharacteristic? _controlChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<List<int>>? _controlSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  Timer? _scanTimeout;
  Timer? _messageTimer;
  BleUiMessage? _pendingMessage;
  DateTime? _lastMessageAt;
  bool _mtuFailureLogged = false;
  bool _cleaningConnection = false;
  bool _disposed = false;

  BleConnectionState _state = BleConnectionState.disconnected;
  BleConnectionState get state => _state;

  final _stateController = StreamController<BleConnectionState>.broadcast();
  Stream<BleConnectionState> get stateStream => _stateController.stream;

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messageStream => _messageController.stream;

  final _uiMessageController = StreamController<BleUiMessage>.broadcast();
  Stream<BleUiMessage> get uiMessageStream => _uiMessageController.stream;

  final List<String> _messages = [];
  List<String> get messages => List.unmodifiable(_messages);

  Future<void> startScan() async {
    if (_disposed || _state == BleConnectionState.scanning) return;
    _setState(BleConnectionState.scanning);

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _publishMessage('Bluetooth is unavailable', BleMessageKind.error);
      _setState(BleConnectionState.disconnected);
      return;
    }

    await _cancelScan();
    _scanSub = FlutterBluePlus.scanResults.listen(
      _onScanResults,
      onError: (Object error) {
        _publishMessage('BLE scan failed: $error', BleMessageKind.error);
        unawaited(_cancelScan());
        _setState(BleConnectionState.disconnected);
      },
    );

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      _scanTimeout = Timer(const Duration(seconds: 10), () {
        if (_state != BleConnectionState.scanning) return;
        unawaited(_cancelScan());
        _publishMessage('Echo device not found', BleMessageKind.error);
        _setState(BleConnectionState.disconnected);
      });
    } catch (error) {
      await _cancelScan();
      _publishMessage('BLE scan failed: $error', BleMessageKind.error);
      _setState(BleConnectionState.disconnected);
    }
  }

  void _onScanResults(List<ScanResult> results) {
    if (_state != BleConnectionState.scanning) return;
    for (final result in results) {
      final advertisedServices = result.advertisementData.serviceUuids
          .map((uuid) => uuid.toString().toLowerCase());
      final deviceName = result.device.platformName.toLowerCase();
      final advertisedName = result.advertisementData.advName.toLowerCase();
      final matchesService = advertisedServices.any(
        (uuid) => uuid.contains(EchoBleUuids.serviceUuid),
      );
      if (matchesService || deviceName.contains('echo') || advertisedName.contains('echo')) {
        _setState(BleConnectionState.connecting);
        unawaited(_connect(result.device));
        return;
      }
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    await _cancelScan();
    _device = device;
    try {
      debugPrint('[BLE] connecting to ${device.platformName} (${device.remoteId})');
      await device.connect(timeout: const Duration(seconds: 8));
      _connectionSub = device.connectionState.listen((connectionState) {
        if (connectionState == BluetoothConnectionState.disconnected) {
          unawaited(_onDisconnected());
        }
      });

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

      final services = await device.discoverServices();
      final echoService = services.firstWhere(
        (service) => service.uuid == Guid(EchoBleUuids.serviceUuid),
        orElse: () => throw StateError('Echo service not found'),
      );
      _audioChar = echoService.characteristics.firstWhere(
        (characteristic) => characteristic.uuid == Guid(EchoBleUuids.audioCharUuid),
        orElse: () => throw StateError('Audio characteristic not found'),
      );
      _controlChar = echoService.characteristics.firstWhere(
        (characteristic) => characteristic.uuid == Guid(EchoBleUuids.controlCharUuid),
        orElse: () => throw StateError('Control characteristic not found'),
      );

      _audioSub = _audioChar!.onValueReceived.listen(
        (value) => unawaited(_onAudioPacket(value)),
        onError: (Object error) =>
            _publishMessage('Audio notification failed: $error', BleMessageKind.error),
      );
      _controlSub = _controlChar!.onValueReceived.listen(
        _onControlPacket,
        onError: (Object error) =>
            _publishMessage('Control notification failed: $error', BleMessageKind.error),
      );
      await _audioChar!.setNotifyValue(true);
      await _controlChar!.setNotifyValue(true);

      _relay.setConnected(true);
      await _relay.sendControl(_buildSetTime());
      await _relay.sendControl(const [0x10]);

      _setState(BleConnectionState.connected);
      _publishMessage('Echo device connected', BleMessageKind.phase);
    } catch (error) {
      debugPrint('[BLE] connection failed: $error');
      _publishMessage('BLE connection failed: $error', BleMessageKind.error);
      try {
        await device.disconnect();
      } catch (_) {}
      await _onDisconnected();
    }
  }

  Future<void> _onAudioPacket(List<int> value) async {
    final events = _assembler.add(value);
    for (final event in events) {
      switch (event) {
        case BleSegmentStarted():
          _publishMessage(
            'Receiving segment ${event.segmentId}',
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
    if (value.length == 8 && value.first == 0x20 && value.last != 0) {
      _publishMessage(
        'Wearable reported error ${value.last}',
        BleMessageKind.error,
      );
    }
  }

  Future<bool> _uploadSegment(BleCompletedSegment segment) {
    return _api.uploadSegment(
      audioData: segment.adpcmBytes,
      recordedAt: segment.recordedAt.toIso8601String(),
      durationMs: segment.durationMs,
      silenceBeforeMs: segment.silenceBeforeMs,
      audioEnergy: segment.averageEnergy,
    );
  }

  Future<void> _writeControl(List<int> value) async {
    final characteristic = _controlChar;
    if (characteristic == null) {
      throw StateError('Control characteristic unavailable');
    }
    await characteristic.write(value, withoutResponse: false);
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
    await _onDisconnected();
  }

  Future<void> _onDisconnected() async {
    if (_cleaningConnection) return;
    _cleaningConnection = true;
    _relay.setConnected(false);
    _assembler.reset();
    await _audioSub?.cancel();
    await _controlSub?.cancel();
    await _connectionSub?.cancel();
    _audioSub = null;
    _controlSub = null;
    _connectionSub = null;
    _device = null;
    _audioChar = null;
    _controlChar = null;
    if (!_disposed) _setState(BleConnectionState.disconnected);
    _cleaningConnection = false;
  }

  Future<void> _cancelScan() async {
    _scanTimeout?.cancel();
    _scanTimeout = null;
    await _scanSub?.cancel();
    _scanSub = null;
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
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

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scanTimeout?.cancel();
    _messageTimer?.cancel();
    unawaited(_scanSub?.cancel());
    unawaited(_audioSub?.cancel());
    unawaited(_controlSub?.cancel());
    unawaited(_connectionSub?.cancel());
    unawaited(FlutterBluePlus.stopScan());
    _relay.dispose();
    _assembler.reset();
    unawaited(_stateController.close());
    unawaited(_messageController.close());
    unawaited(_uiMessageController.close());
  }
}

final bleService = BleService();
