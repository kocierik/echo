import 'dart:typed_data';

import '../../models/device_status.dart';

final class DeviceTelemetry {
  const DeviceTelemetry({
    required this.muted,
    required this.overflowed,
    required this.batteryPercent,
    required this.bufferCount,
    required this.bufferBytes,
    required this.droppedSegments,
    this.cameraAvailable = false,
    this.microSd,
  });

  final bool muted;
  final bool overflowed;
  final int? batteryPercent;
  final int bufferCount;
  final int bufferBytes;
  final int droppedSegments;

  /// Protocol 3: a camera is connected and photos can be taken.
  final bool cameraAvailable;

  /// Protocol 5: the microSD; null before.
  final MicroSd? microSd;
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

/// Where a firmware update stands on the wearable (OTA_STATUS).
enum OtaState { receiving, done, failed }

/// Where turning Echo off stands (POWER_STATE, firmware 0.10.0 on). Refused: Echo stays on
/// because it is updating.
enum DevicePowerState { on, turningOff, off, refused }

final class OtaStatus {
  const OtaStatus(this.state, this.error, this.received);

  final OtaState state;

  /// Why it failed, as [DeviceProtocol.otaErrorMessage] explains; 0 otherwise.
  final int error;

  /// Bytes the wearable has written.
  final int received;
}

abstract final class DeviceProtocol {
  /// 2: audio; 3: audio and photos; 4: firmware updates over BLE; 5: the microSD in the
  /// status; 6: firmware updates signed with the release key. All are accepted, so an app
  /// update never cuts off a wearable that still runs a previous firmware.
  static const Set<int> supportedVersions = {2, 3, 4, 5, 6};
  static const int photoVersion = 3;
  static const int otaVersion = 4;
  static const int microSdVersion = 5;
  static const int signedOtaVersion = 6;
  static const int _frameSetMuted = 0x15;
  static const int _frameSetMicGain = 0x1B;

  /// The microphone's gain the app can set (firmware 0.9.3 on), and its default.
  static const int maxMicGain = 8;
  static const int defaultMicGain = 3;
  static const String micGainFirmware = '0.9.3';

  /// Turning Echo off from the app (firmware 0.10.0 on; no protocol bump).
  static const String powerOffFirmware = '0.10.0';
  static const int _framePowerOff = 0x1C;
  static const int framePowerState = 0x24;
  /// Firmware 0.11.0 on: the pendant just heard its wake phrase.
  static const int frameWakeHeard = 0x25;
  static const int _frameForgetBond = 0x16;
  static const int _frameForgetBondOk = 0x17;
  static const int _frameTakePhoto = 0x18;
  static const int _frameOtaBegin = 0x19;
  static const int _frameOtaAbort = 0x1A;
  static const int frameOtaStatus = 0x23;
  static const int otaDataHeaderSize = 4;
  static const int frameDeviceStatus = 0x20;
  static const int frameDeviceInfo = 0x21;
  static const int framePhotoFailed = 0x22;
  static const int _frameDeviceStatus = 0x20;
  static const int _frameDeviceInfo = 0x21;
  static const int _deviceStatusSize = 14;
  static const int _deviceStatusSizeV5 = 26;
  static const int _deviceInfoSize = 5;

  static DeviceTelemetry parseStatus(Uint8List bytes) {
    if (bytes.length < 2) {
      throw const DeviceProtocolException('invalid device status length');
    }
    if (bytes[0] != _frameDeviceStatus) {
      throw const DeviceProtocolException('invalid device status type');
    }
    final version = bytes[1];
    if (!supportedVersions.contains(version)) {
      throw const DeviceProtocolException('unsupported device status version');
    }
    final withCard = version >= microSdVersion;
    if (bytes.length != (withCard ? _deviceStatusSizeV5 : _deviceStatusSize)) {
      throw const DeviceProtocolException('invalid device status length');
    }
    final flags = bytes[2];
    final reserved = withCard ? 0xf0 : (version >= photoVersion ? 0xf8 : 0xfc);
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
      microSd: withCard
          ? MicroSd(
              inUse: (flags & 0x08) != 0,
              totalMb: data.getUint32(14, Endian.little),
              freeMb: data.getUint32(18, Endian.little),
              pendingKb: data.getUint32(22, Endian.little),
            )
          : null,
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

  static Uint8List setMicGain(int gain) => Uint8List.fromList([
    _frameSetMicGain,
    gain.clamp(1, maxMicGain),
  ]);

  static Uint8List forgetBond() => Uint8List.fromList([_frameForgetBond]);

  static Uint8List takePhoto() => Uint8List.fromList([_frameTakePhoto]);

  static Uint8List powerOff() => Uint8List.fromList([_framePowerOff, 1]);

  static Uint8List cancelPowerOff() => Uint8List.fromList([_framePowerOff, 0]);

  /// WAKE_HEARD: [type] alone.
  static bool isWakeHeard(List<int> bytes) =>
      bytes.length == 1 && bytes.first == frameWakeHeard;

  /// POWER_STATE, or null for any other frame.
  static DevicePowerState? parsePowerState(List<int> bytes) {
    if (bytes.length != 3 || bytes.first != framePowerState) return null;
    return switch (bytes[1]) {
      0 => DevicePowerState.on,
      1 => DevicePowerState.turningOff,
      2 => DevicePowerState.off,
      3 => DevicePowerState.refused,
      _ => null,
    };
  }

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

  /// OTA_BEGIN: the image size and its SHA-256, checked by the wearable at the end, and
  /// from protocol 6 the release key's signature of that SHA-256 (raw r||s), checked first.
  static Uint8List otaBegin(int size, List<int> sha256, {List<int>? signature}) {
    if (sha256.length != 32) throw ArgumentError('SHA-256 must be 32 bytes');
    if (signature != null && signature.length != 64) {
      throw ArgumentError('The signature must be 64 bytes');
    }
    final frame = Uint8List(37 + (signature?.length ?? 0));
    frame[0] = _frameOtaBegin;
    ByteData.sublistView(frame).setUint32(1, size, Endian.little);
    frame.setRange(5, 37, sha256);
    if (signature != null) frame.setRange(37, 101, signature);
    return frame;
  }

  static Uint8List otaAbort() => Uint8List.fromList([_frameOtaAbort]);

  /// A chunk of the image for the OTA characteristic: [offset u32, bytes].
  static Uint8List otaChunk(int offset, List<int> bytes) {
    final frame = Uint8List(otaDataHeaderSize + bytes.length);
    ByteData.sublistView(frame).setUint32(0, offset, Endian.little);
    frame.setRange(otaDataHeaderSize, frame.length, bytes);
    return frame;
  }

  /// OTA_STATUS, or null for any other frame.
  static OtaStatus? parseOtaStatus(List<int> bytes) {
    if (bytes.length != 7 || bytes.first != frameOtaStatus) return null;
    final state = switch (bytes[1]) {
      1 => OtaState.receiving,
      2 => OtaState.done,
      3 => OtaState.failed,
      _ => null,
    };
    if (state == null) return null;
    final received = ByteData.sublistView(Uint8List.fromList(bytes))
        .getUint32(3, Endian.little);
    return OtaStatus(state, bytes[2], received);
  }

  /// What an OTA_STATUS error means for the user.
  static String otaErrorMessage(int error) => switch (error) {
        1 => 'Echo still has audio or a photo to send. Try again in a minute.',
        2 => 'This firmware is too large for Echo.',
        3 => 'Echo\'s battery is too low. Charge it and try again.',
        4 => 'Echo could not write the update. Try again.',
        5 || 9 => 'The transfer was interrupted. Try again.',
        6 => 'The firmware arrived damaged. Try again.',
        7 => 'This is not a firmware Echo can run.',
        10 => 'This firmware is not signed by Echo, so Echo refused it.',
        _ => 'The update did not go through. Try again.',
      };

  static bool isForgetBondOk(List<int> bytes) =>
      bytes.length == 1 && bytes.first == _frameForgetBondOk;
}
