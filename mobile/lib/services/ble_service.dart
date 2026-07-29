import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'api_service.dart';

/// BLE UUIDs matching the firmware GATT server
/// Update these when you define them in the ESP32 firmware
class EchoBleUuids {
  static const serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const audioCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
  static const controlCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a9';
}

class EchoBleProtocol {
  static const int frameSegmentStart = 0x01;
  static const int frameSegmentMetadata = 0x02;
  static const int frameSegmentData = 0x03;
  static const int frameReady = 0x10;
  static const int frameAckWindow = 0x11;
  static const int frameRestartSegment = 0x12;
  static const int frameUploadOk = 0x13;
  static const int frameSetTime = 0x14;
  static const int frameDeviceStatus = 0x20;
  static const int protocolVersion = 1;
  static const int segmentStartSize = 20;
  static const int segmentMetadataSize = 19;
  static const int segmentDataHeaderSize = 7;
  static const int ackWindowSize = 7;
  static const int segmentCommandSize = 5;
  static const int readySize = 1;
  static const int setTimeSize = 11;
  static const int deviceStatusSize = 8;

  static int readU16(Uint8List data, int offset) {
    return data[offset] | (data[offset + 1] << 8);
  }

  static int readU32(Uint8List data, int offset) {
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  static int readU64(Uint8List data, int offset) {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value |= data[offset + i] << (8 * i);
    }
    return value;
  }

  static Uint8List buildAckWindow(int segmentId, int highestSequence) {
    final bytes = Uint8List(ackWindowSize);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, frameAckWindow);
    view.setUint32(1, segmentId, Endian.little);
    view.setUint16(5, highestSequence, Endian.little);
    return bytes;
  }

  static Uint8List buildUploadOk(int segmentId) {
    final bytes = Uint8List(segmentCommandSize);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, frameUploadOk);
    view.setUint32(1, segmentId, Endian.little);
    return bytes;
  }
}

enum BleConnectionState { disconnected, scanning, connecting, connected }

/// BLE relay service: receives audio from device via BLE, forwards to backend via HTTP.
///
/// Flow:
/// 1. Scan for Echo device (by service UUID)
/// 2. Connect and discover services
/// 3. Subscribe to audio characteristic notifications
/// 4. Reassemble ADPCM packets into complete segments
/// 5. POST each segment to backend (same as Wi-Fi direct)
class BleService {
  final ApiService _api = ApiService();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _audioChar;
  BluetoothCharacteristic? _controlChar;
  StreamSubscription? _scanSub;
  StreamSubscription? _audioSub;

  // Segment reassembly buffer
  final List<int> _segmentBuffer = [];
  int _expectedLength = 0;
  int _segmentId = 0;
  int _totalChunks = 0;
  int _highestSequence = -1;
  DateTime? _segmentStartTime;

  // State
  BleConnectionState _state = BleConnectionState.disconnected;
  BleConnectionState get state => _state;

  // Stream for UI updates
  final _stateController = StreamController<BleConnectionState>.broadcast();
  Stream<BleConnectionState> get stateStream => _stateController.stream;

  // Stream for incoming messages/notifications from device (for UI)
  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messageStream => _messageController.stream;
  // Persistent in-memory history of messages (most recent first)
  final List<String> _messages = [];
  List<String> get messages => List.unmodifiable(_messages);

  void _setState(BleConnectionState s) {
    _state = s;
    _stateController.add(s);
  }

  /// Start scanning for the Echo device
  Future<void> startScan() async {
    if (_state == BleConnectionState.scanning) return;
    _setState(BleConnectionState.scanning);

    // Check if Bluetooth is on
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _setState(BleConnectionState.disconnected);
      return;
    }

    // Start an unfiltered scan to capture all advertisements — some firmwares
    // put the service UUID only in the scan response, not the primary adv packet.
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final deviceName = r.device.platformName;
        final advertisedName = r.advertisementData.advName;
        final advSvc = r.advertisementData.serviceUuids
            .map((g) => g.toString().toLowerCase())
            .toList();
        final addr = r.device.remoteId.toString();
        // Debug log to aid troubleshooting
        print('[BLE] scan result: name="$deviceName" advName="$advertisedName" addr=$addr advSvcs=$advSvc');

        // Match by advertised service UUID OR by device name containing "Echo"
        final serviceUuidLower = EchoBleUuids.serviceUuid.toLowerCase();
        final matchesService = advSvc.any((uuid) => uuid.contains(serviceUuidLower));
        final nameContainsEcho = deviceName.toLowerCase().contains('echo') || advertisedName.toLowerCase().contains('echo');
        if (matchesService || nameContainsEcho) {
          // Found our device
          FlutterBluePlus.stopScan();
          _scanSub?.cancel();
          _scanSub = null;
          _connect(r.device);
          return;
        }
      }
    });

    // Handle scan timeout
    Future.delayed(const Duration(seconds: 10), () async {
      if (_state == BleConnectionState.scanning) {
        await FlutterBluePlus.stopScan();
        await _scanSub?.cancel();
        _scanSub = null;
        _setState(BleConnectionState.disconnected);
      }
    });
  }

  /// Connect to the Echo device
  Future<void> _connect(BluetoothDevice device) async {
    _setState(BleConnectionState.connecting);
    _device = device;

    try {
      print('[BLE] connecting to ${device.platformName} (${device.remoteId})');
      await device.connect(timeout: const Duration(seconds: 8));
      print('[BLE] connect succeeded');

      // Skip requesting a larger MTU on Linux/BlueZ for now.
      // This can help avoid early supervision timeout / transport failure.
      print('[BLE] skipping MTU request for stability');

      print('[BLE] starting service discovery');
      final services = await device.discoverServices();
      print('[BLE] discovered ${services.length} services');

      final echoService = services.firstWhere(
        (s) => s.uuid == Guid(EchoBleUuids.serviceUuid),
        orElse: () => throw Exception('Echo service not found'),
      );
      print('[BLE] found Echo service ${echoService.uuid}');

      _audioChar = echoService.characteristics.firstWhere(
        (c) => c.uuid == Guid(EchoBleUuids.audioCharUuid),
        orElse: () => throw Exception('Audio characteristic not found'),
      );
      print('[BLE] found audio characteristic ${_audioChar!.uuid}');

      _controlChar = echoService.characteristics.firstWhere(
        (c) => c.uuid == Guid(EchoBleUuids.controlCharUuid),
        orElse: () => throw Exception('Control characteristic not found'),
      );
      print('[BLE] found control characteristic ${_controlChar!.uuid}');

      print('[BLE] enabling audio notifications');
      await _audioChar!.setNotifyValue(true);
      _audioSub = _audioChar!.onValueReceived.listen(_onAudioPacket);
      print('[BLE] audio notifications enabled');

      print('[BLE] enabling control notifications');
      await _controlChar!.setNotifyValue(true);
      _controlChar!.onValueReceived.listen(_onControlPacket);
      print('[BLE] control notifications enabled');

      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final tzOffsetMinutes = DateTime.now().timeZoneOffset.inMinutes;
      final bytes = <int>[];
      bytes.add(0x14);
      final b = ByteData(8)..setInt64(0, nowMs, Endian.little);
      bytes.addAll(b.buffer.asUint8List());
      final b2 = ByteData(2)..setInt16(0, tzOffsetMinutes, Endian.little);
      bytes.addAll(b2.buffer.asUint8List());
      print('[BLE] sending SET_TIME timezone=$tzOffsetMinutes nowMs=$nowMs');
      try {
        await _controlChar!.write(bytes, withoutResponse: false);
        print('[BLE] SET_TIME write succeeded');
      } catch (e) {
        print('[BLE] SET_TIME write failed: $e');
      }

      print('[BLE] sending READY');
      try {
        await _controlChar!.write([0x10], withoutResponse: false);
        print('[BLE] READY write succeeded');
      } catch (e) {
        print('[BLE] READY write failed: $e');
      }

      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      _setState(BleConnectionState.connected);
    } catch (e) {
      print('[BLE] connection failed: $e');
      _setState(BleConnectionState.disconnected);
      _device = null;
    }
  }

  /// Handle incoming audio packet from BLE
  ///
  /// Packet format (defined by firmware):
  /// - Segment start:      [0x01][segmentId:4][version:1][totalLength:4][durationMs:4][totalChunks:2][crc:4][optional payload]
  /// - Segment metadata:   [0x02][segmentId:4][recordedAtUnixSeconds:8][silenceBeforeMs:4][avgEnergy:2]
  /// - Segment data chunk: [0x03][segmentId:4][sequence:2][payload...]
  Future<void> _onAudioPacket(List<int> data) async {
    if (data.isEmpty) return;

    final packetType = data[0];
    final packet = Uint8List.fromList(data);

    switch (packetType) {
      case EchoBleProtocol.frameSegmentStart:
        if (packet.length < EchoBleProtocol.segmentStartSize) return;
        final version = packet[5];
        if (version != EchoBleProtocol.protocolVersion) return;

        _segmentId = EchoBleProtocol.readU32(packet, 1);
        _expectedLength = EchoBleProtocol.readU32(packet, 6);
        _totalChunks = EchoBleProtocol.readU16(packet, 14);
        _segmentBuffer.clear();
        _highestSequence = -1;
        _segmentStartTime = DateTime.now().toUtc();
        if (packet.length > EchoBleProtocol.segmentStartSize) {
          _segmentBuffer.addAll(packet.sublist(EchoBleProtocol.segmentStartSize));
        }
        print('[BLE] segment start id=$_segmentId len=$_expectedLength chunks=$_totalChunks');
        final msg = 'Segment start: id=$_segmentId len=$_expectedLength';
        _messages.insert(0, msg);
        if (_messages.length > 500) _messages.removeLast();
        _messageController.add(msg);
        break;

      case EchoBleProtocol.frameSegmentMetadata:
        if (packet.length != EchoBleProtocol.segmentMetadataSize) return;
        final segmentId = EchoBleProtocol.readU32(packet, 1);
        if (segmentId != _segmentId) return;
        final recordedAtSeconds = EchoBleProtocol.readU64(packet, 5);
        _segmentStartTime = DateTime.fromMillisecondsSinceEpoch(recordedAtSeconds * 1000, isUtc: true);
        print('[BLE] segment metadata id=$segmentId recordedAt=$recordedAtSeconds');
        final msg = 'Segment metadata: id=$segmentId';
        _messages.insert(0, msg);
        if (_messages.length > 500) _messages.removeLast();
        _messageController.add(msg);
        break;

      case EchoBleProtocol.frameSegmentData:
        if (packet.length < EchoBleProtocol.segmentDataHeaderSize) return;
        final segmentId = EchoBleProtocol.readU32(packet, 1);
        if (segmentId != _segmentId) return;
        final sequence = EchoBleProtocol.readU16(packet, 5);
        final payload = packet.sublist(EchoBleProtocol.segmentDataHeaderSize);
        _segmentBuffer.addAll(payload);
        _highestSequence = sequence;
        print('[BLE] segment data seq=$sequence payload=${payload.length}');
        // Notify UI every Nth chunk or last chunk to avoid spam
        if (sequence == 0 || ((sequence + 1) % 8) == 0 || sequence == (_totalChunks - 1)) {
          final msg = 'Receiving segment $segmentId chunk $sequence';
          _messages.insert(0, msg);
          if (_messages.length > 500) _messages.removeLast();
          _messageController.add(msg);
        }

        final isWindowEnd = ((sequence + 1) % 8) == 0;
        final isLastChunk = sequence == (_totalChunks - 1);
        if (isWindowEnd || isLastChunk) {
          _sendAckWindow();
        }
        if (isLastChunk) {
          // Last chunk received — finalize (upload) first, then ACK to device on success
          final success = await _finalizeSegment();
          if (success) {
            _sendUploadOk();
          } else {
            print('[BLE] upload failed for segment=$_segmentId — will NOT send UPLOAD_OK');
            _messageController.add('Upload failed for segment $_segmentId');
          }
        }
        break;

      default:
        break;
    }
  }

  Future<void> _sendControlFrame(Uint8List value) async {
    if (_controlChar == null) return;
    try {
      await _controlChar!.write(value, withoutResponse: false);
    } catch (e) {
      print('[BLE] failed control write: $e');
    }
  }

  void _sendAckWindow() {
    if (_segmentId == 0 || _highestSequence < 0) return;
    final ack = EchoBleProtocol.buildAckWindow(_segmentId, _highestSequence);
    _sendControlFrame(ack);
    print('[BLE] sent ACK_WINDOW id=$_segmentId highestSeq=$_highestSequence');
  }

  void _sendUploadOk() {
    if (_segmentId == 0) return;
    final ok = EchoBleProtocol.buildUploadOk(_segmentId);
    _sendControlFrame(ok);
    print('[BLE] sent UPLOAD_OK id=$_segmentId');
  }

  /// Handle incoming control packets from firmware
  void _onControlPacket(List<int> data) {
    if (data.isEmpty) return;
    final type = data[0];
    switch (type) {
      case EchoBleProtocol.frameAckWindow:
        // expect: type(1) + segment_id(4) + highest_seq(2)
        if (data.length >= EchoBleProtocol.ackWindowSize) {
          final segId = ByteData.sublistView(Uint8List.fromList(data.sublist(1, 5))).getUint32(0, Endian.little);
          final highest = ByteData.sublistView(Uint8List.fromList(data.sublist(5, 7))).getUint16(0, Endian.little);
          print('[BLE] control ACK_WINDOW seg=$segId highest=$highest');
        }
        break;
      case EchoBleProtocol.frameUploadOk:
        // type + segment_id
        if (data.length >= EchoBleProtocol.segmentCommandSize) {
          final segId = ByteData.sublistView(Uint8List.fromList(data.sublist(1, 5))).getUint32(0, Endian.little);
          print('[BLE] control UPLOAD_OK seg=$segId');
          final msg = 'Upload OK: segment $segId';
          _messages.insert(0, msg);
          if (_messages.length > 500) _messages.removeLast();
          _messageController.add(msg);
        }
        break;
      case 0x20: // DEVICE_STATUS
        // type + counts... ignore for now
        break;
      default:
        // unknown
        break;
    }
  }

  /// Segment complete — forward to backend
  /// Finalize the assembled segment by uploading to backend.
  /// Returns true on successful upload, false otherwise.
  Future<bool> _finalizeSegment() async {
    if (_segmentBuffer.isEmpty) return false;

    final adpcmData = Uint8List.fromList(_segmentBuffer);
    final startTime = _segmentStartTime ?? DateTime.now().toUtc();

    // Calculate approximate duration from ADPCM data length
    // ADPCM at 16kHz: 8KB/s, so duration_ms = length / 8
    final durationMs = (adpcmData.length / 8).round();

    print('[BLE] uploading segment=$_segmentId len=${adpcmData.length} recordedAt=$startTime durationMs=$durationMs');

    try {
      final res = await _api.uploadSegment(
        audioData: adpcmData,
        recordedAt: startTime.toIso8601String(),
        durationMs: durationMs,
      );
      print('[BLE] uploadSegment succeeded for segment=$_segmentId');
      _messageController.add('Uploaded segment $_segmentId');
      _segmentBuffer.clear();
      return true;
    } catch (e) {
      print('[BLE] uploadSegment FAILED for segment=$_segmentId: $e');
      _messageController.add('Upload failed for segment $_segmentId');
      // keep buffer for retry
      return false;
    }
  }

  void _onDisconnected() {
    _audioSub?.cancel();
    _audioSub = null;
    _device = null;
    _audioChar = null;
    _controlChar = null;
    _setState(BleConnectionState.disconnected);
  }

  /// Disconnect from device
  Future<void> disconnect() async {
    await _audioSub?.cancel();
    await _device?.disconnect();
    _onDisconnected();
  }

  /// Dispose resources
  void dispose() {
    _scanSub?.cancel();
    _audioSub?.cancel();
    _stateController.close();
    _messageController.close();
  }
}

final bleService = BleService();
