import 'dart:typed_data';

final class DeviceTelemetry {
  const DeviceTelemetry({
    required this.muted,
    required this.overflowed,
    required this.batteryPercent,
    required this.bufferCount,
    required this.bufferBytes,
    required this.droppedSegments,
  });

  final bool muted;
  final bool overflowed;
  final int? batteryPercent;
  final int bufferCount;
  final int bufferBytes;
  final int droppedSegments;
}

final class DeviceInfo {
  const DeviceInfo({
    required this.protocolVersion,
    required this.firmwareMajor,
    required this.firmwareMinor,
    required this.firmwarePatch,
  });

  final int protocolVersion;
  final int firmwareMajor;
  final int firmwareMinor;
  final int firmwarePatch;
}

final class DeviceProtocolException implements Exception {
  const DeviceProtocolException(this.message);

  final String message;

  @override
  String toString() => 'DeviceProtocolException: $message';
}

abstract final class DeviceProtocol {
  static const int _protocolVersion = 2;
  static const int _frameSetMuted = 0x15;
  static const int _frameForgetBond = 0x16;
  static const int _frameForgetBondOk = 0x17;
  static const int _frameDeviceStatus = 0x20;
  static const int _frameDeviceInfo = 0x21;
  static const int _deviceStatusSize = 14;
  static const int _deviceInfoSize = 5;

  static DeviceTelemetry parseStatus(Uint8List bytes) {
    if (bytes.length != _deviceStatusSize) {
      throw const DeviceProtocolException('invalid device status length');
    }
    if (bytes[0] != _frameDeviceStatus) {
      throw const DeviceProtocolException('invalid device status type');
    }
    if (bytes[1] != _protocolVersion) {
      throw const DeviceProtocolException('unsupported device status version');
    }
    final flags = bytes[2];
    if ((flags & 0xfc) != 0) {
      throw const DeviceProtocolException('reserved device status flags are set');
    }
    final battery = bytes[3];
    if (battery > 100 && battery != 255) {
      throw const DeviceProtocolException('invalid battery percent');
    }

    final data = ByteData.sublistView(bytes);
    return DeviceTelemetry(
      muted: (flags & 0x01) != 0,
      overflowed: (flags & 0x02) != 0,
      batteryPercent: battery == 255 ? null : battery,
      bufferCount: data.getUint16(4, Endian.little),
      bufferBytes: data.getUint32(6, Endian.little),
      droppedSegments: data.getUint32(10, Endian.little),
    );
  }

  static DeviceInfo parseInfo(Uint8List bytes) {
    if (bytes.length != _deviceInfoSize) {
      throw const DeviceProtocolException('invalid device info length');
    }
    if (bytes[0] != _frameDeviceInfo) {
      throw const DeviceProtocolException('invalid device info type');
    }
    if (bytes[1] != _protocolVersion) {
      throw const DeviceProtocolException('unsupported device info version');
    }
    return DeviceInfo(
      protocolVersion: bytes[1],
      firmwareMajor: bytes[2],
      firmwareMinor: bytes[3],
      firmwarePatch: bytes[4],
    );
  }

  static Uint8List setMuted(bool muted) => Uint8List.fromList([
    _frameSetMuted,
    muted ? 1 : 0,
  ]);

  static Uint8List forgetBond() => Uint8List.fromList([_frameForgetBond]);

  static bool isForgetBondOk(List<int> bytes) =>
      bytes.length == 1 && bytes.first == _frameForgetBondOk;
}
