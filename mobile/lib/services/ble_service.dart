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
  DateTime? _segmentStartTime;

  // State
  BleConnectionState _state = BleConnectionState.disconnected;
  BleConnectionState get state => _state;

  // Stream for UI updates
  final _stateController = StreamController<BleConnectionState>.broadcast();
  Stream<BleConnectionState> get stateStream => _stateController.stream;

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

    await FlutterBluePlus.startScan(
      withServices: [Guid(EchoBleUuids.serviceUuid)],
      timeout: const Duration(seconds: 10),
    );

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.advertisementData.serviceUuids.contains(Guid(EchoBleUuids.serviceUuid))) {
          // Found our device
          FlutterBluePlus.stopScan();
          _scanSub?.cancel();
          _connect(r.device);
          return;
        }
      }
    });

    // Handle scan timeout
    Future.delayed(const Duration(seconds: 10), () {
      if (_state == BleConnectionState.scanning) {
        FlutterBluePlus.stopScan();
        _setState(BleConnectionState.disconnected);
      }
    });
  }

  /// Connect to the Echo device
  Future<void> _connect(BluetoothDevice device) async {
    _setState(BleConnectionState.connecting);
    _device = device;

    try {
      await device.connect(timeout: const Duration(seconds: 8));

      // Request higher MTU for larger packets
      await device.requestMtu(512);

      // Discover services
      final services = await device.discoverServices();
      final echoService = services.firstWhere(
        (s) => s.uuid == Guid(EchoBleUuids.serviceUuid),
        orElse: () => throw Exception('Echo service not found'),
      );

      // Find characteristics
      _audioChar = echoService.characteristics.firstWhere(
        (c) => c.uuid == Guid(EchoBleUuids.audioCharUuid),
        orElse: () => throw Exception('Audio characteristic not found'),
      );

      _controlChar = echoService.characteristics.firstWhere(
        (c) => c.uuid == Guid(EchoBleUuids.controlCharUuid),
        orElse: () => throw Exception('Control characteristic not found'),
      );

      // Subscribe to audio data notifications
      await _audioChar!.setNotifyValue(true);
      _audioSub = _audioChar!.onValueReceived.listen(_onAudioPacket);

      // Listen for disconnection
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      _setState(BleConnectionState.connected);
    } catch (e) {
      _setState(BleConnectionState.disconnected);
      _device = null;
    }
  }

  /// Handle incoming audio packet from BLE
  ///
  /// Packet format (defined by firmware):
  /// - First packet of segment: [0x01] [4 bytes: total_length] [2 bytes: duration_ms] [data...]
  /// - Continuation packet:     [0x02] [data...]
  /// - Last packet of segment:  [0x03] [data...]
  void _onAudioPacket(List<int> data) {
    if (data.isEmpty) return;

    final packetType = data[0];

    switch (packetType) {
      case 0x01: // Start of segment
        if (data.length < 7) return;
        _segmentBuffer.clear();
        _expectedLength = ByteData.view(Uint8List.fromList(data.sublist(1, 5)).buffer).getUint32(0, Endian.little);
        _segmentStartTime = DateTime.now().toUtc();
        _segmentBuffer.addAll(data.sublist(7));
        break;

      case 0x02: // Continuation
        _segmentBuffer.addAll(data.sublist(1));
        break;

      case 0x03: // End of segment
        _segmentBuffer.addAll(data.sublist(1));
        _finalizeSegment();
        break;
    }
  }

  /// Segment complete — forward to backend
  Future<void> _finalizeSegment() async {
    if (_segmentBuffer.isEmpty) return;

    final adpcmData = Uint8List.fromList(_segmentBuffer);
    final startTime = _segmentStartTime ?? DateTime.now().toUtc();

    // Calculate approximate duration from ADPCM data length
    // ADPCM at 16kHz: 8KB/s, so duration_ms = (length / 8) * 1000
    final durationMs = (adpcmData.length / 8 * 1000).round();

    // Forward to backend via HTTP (same as device would do directly)
    try {
      await _api.uploadSegment(
        audioData: adpcmData,
        recordedAt: startTime.toIso8601String(),
        durationMs: durationMs,
      );
    } catch (e) {
      // TODO: buffer locally and retry later
    }

    _segmentBuffer.clear();
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
  }
}
