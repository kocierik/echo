import 'dart:typed_data';

final class DeviceTelemetry {
  const DeviceTelemetry({
    required this.muted,
    required this.overflowed,
    required this.batteryPercent,
    required this.bufferCount,
    required this.bufferBytes,
    required this.droppedSegments,
    this.cameraAvailable = false,
  });

  final bool muted;
  final bool overflowed;
  final int? batteryPercent;
  final int bufferCount;
  final int bufferBytes;
  final int droppedSegments;

  /// Protocol 3: a camera is connected and photos can be taken.
  final bool cameraAvailable;
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
  /// 2: audio; 3: audio and photos. Both are accepted, so an app update never cuts
  /// off a wearable that still runs the previous firmware.
  static const Set<int> supportedVersions = {2, 3};
  static const int photoVersion = 3;
  static const int _frameSetMuted = 0x15;
  static const int _frameForgetBond = 0x16;
  static const int _frameForgetBondOk = 0x17;
  static const int _frameTakePhoto = 0x18;
  static const int frameDeviceStatus = 0x20;
  static const int frameDeviceInfo = 0x21;
  static const int framePhotoFailed = 0x22;
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
    final version = bytes[1];
    if (!supportedVersions.contains(version)) {
      throw const DeviceProtocolException('unsupported device status version');
    }
    final flags = bytes[2];
    final reserved = version >= photoVersion ? 0xf8 : 0xfc;
    if ((flags & reserved) != 0) {
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
      cameraAvailable: (flags & 0x04) != 0,
    );
  }

  static DeviceInfo parseInfo(Uint8List bytes) {
    if (bytes.length != _deviceInfoSize) {
      throw const DeviceProtocolException('invalid device info length');
    }
    if (bytes[0] != _frameDeviceInfo) {
      throw const DeviceProtocolException('invalid device info type');
    }
    if (!supportedVersions.contains(bytes[1])) {
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

  static Uint8List takePhoto() => Uint8List.fromList([_frameTakePhoto]);

  /// Why the wearable took no photo, as the backend names it; null when the frame
  /// is not a PHOTO_FAILED.
  static String? parsePhotoFailed(List<int> bytes) {
    if (bytes.length != 2 || bytes.first != framePhotoFailed) return null;
    return switch (bytes[1]) {
      1 => 'muted',
      2 => 'capture_failed',
      3 => 'busy',
      4 => 'no_camera',
      _ => 'capture_failed',
    };
  }

  static bool isForgetBondOk(List<int> bytes) =>
      bytes.length == 1 && bytes.first == _frameForgetBondOk;
}
