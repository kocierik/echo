import 'device_protocol.dart';

enum DeviceAdapterState { on, off, unauthorized, unavailable }

enum DeviceBlePhase {
  disconnected,
  scanning,
  connecting,
  bonding,
  ready,
}

abstract interface class DeviceBlePort {
  DeviceAdapterState get adapterState;
  Stream<DeviceAdapterState> get adapterStateStream;

  DeviceBlePhase get phase;
  Stream<DeviceBlePhase> get phaseStream;
  Stream<DeviceTelemetry> get telemetryStream;
  Stream<DeviceInfo> get deviceInfoStream;

  Future<String> pair();
  Future<void> connectSaved(String remoteId);
  Future<void> setMuted(bool muted);
  Future<void> setMicGain(int gain);
  Future<void> forgetBond();
  Future<void> disconnect();
  Future<void> dispose();
}