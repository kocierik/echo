import 'dart:typed_data';

import 'package:echo_app/services/device/device_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceProtocol', () {
    test('parses the exact device status v2 vector', () {
      final status = DeviceProtocol.parseStatus(Uint8List.fromList([
        0x20, 0x02, 0x03, 0xff, 0x03, 0x00,
        0xe0, 0x2e, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00,
      ]));

      expect(status.muted, isTrue);
      expect(status.overflowed, isTrue);
      expect(status.batteryPercent, isNull);
      expect(status.bufferCount, 3);
      expect(status.bufferBytes, 12000);
      expect(status.droppedSegments, 7);
      expect(status, isA<DeviceTelemetry>());
    });

    test('maps unavailable battery to null', () {
      final status = DeviceProtocol.parseStatus(Uint8List.fromList([
        0x20, 0x02, 0x00, 0xff, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]));

      expect(status.batteryPercent, isNull);
    });

    test('parses device info', () {
      final info = DeviceProtocol.parseInfo(
        Uint8List.fromList([0x21, 0x02, 0x01, 0x02, 0x03]),
      );

      expect(info.protocolVersion, 2);
      expect(info.firmwareMajor, 1);
      expect(info.firmwareMinor, 2);
      expect(info.firmwarePatch, 3);
    });

    test('encodes privacy commands', () {
      expect(DeviceProtocol.setMuted(false), orderedEquals([0x15, 0x00]));
      expect(DeviceProtocol.setMuted(true), orderedEquals([0x15, 0x01]));
      expect(DeviceProtocol.forgetBond(), orderedEquals([0x16]));
      expect(DeviceProtocol.isForgetBondOk([0x17]), isTrue);
      expect(DeviceProtocol.isForgetBondOk([0x17, 0x00]), isFalse);
    });

    test('rejects status with wrong type', () {
      expect(
        () => DeviceProtocol.parseStatus(_validStatus()..[0] = 0x21),
        throwsA(isA<DeviceProtocolException>()),
      );
    });

    test('rejects status with wrong version', () {
      expect(
        () => DeviceProtocol.parseStatus(_validStatus()..[1] = 0x01),
        throwsA(isA<DeviceProtocolException>()),
      );
    });

    test('rejects status with wrong length', () {
      expect(
        () => DeviceProtocol.parseStatus(Uint8List(13)),
        throwsA(isA<DeviceProtocolException>()),
      );
      expect(
        () => DeviceProtocol.parseStatus(Uint8List(15)),
        throwsA(isA<DeviceProtocolException>()),
      );
    });

    test('rejects reserved status flags', () {
      expect(
        () => DeviceProtocol.parseStatus(_validStatus()..[2] = 0x04),
        throwsA(isA<DeviceProtocolException>()),
      );
    });

    test('reads the camera flag from protocol 3 and keeps 2 working', () {
      final v3 = DeviceProtocol.parseStatus(_validStatus()
        ..[1] = 0x03
        ..[2] = 0x04);
      expect(v3.cameraAvailable, isTrue);
      expect(v3.muted, isFalse);
      expect(DeviceProtocol.parseStatus(_validStatus()).cameraAvailable, isFalse);
      expect(
        () => DeviceProtocol.parseStatus(_validStatus()
          ..[1] = 0x03
          ..[2] = 0x08),
        throwsA(isA<DeviceProtocolException>()),
      );
    });

    test('encodes TAKE_PHOTO and decodes PHOTO_FAILED reasons', () {
      expect(DeviceProtocol.takePhoto(), orderedEquals([0x18]));
      expect(DeviceProtocol.parsePhotoFailed([0x22, 1]), 'muted');
      expect(DeviceProtocol.parsePhotoFailed([0x22, 2]), 'capture_failed');
      expect(DeviceProtocol.parsePhotoFailed([0x22, 3]), 'busy');
      expect(DeviceProtocol.parsePhotoFailed([0x22, 4]), 'no_camera');
      expect(DeviceProtocol.parsePhotoFailed([0x20, 1]), isNull);
      expect(DeviceProtocol.parsePhotoFailed([0x22]), isNull);
    });

    test('rejects invalid battery percent', () {
      expect(
        () => DeviceProtocol.parseStatus(_validStatus()..[3] = 101),
        throwsA(isA<DeviceProtocolException>()),
      );
    });

    test('rejects info with wrong type, version, or length', () {
      expect(
        () => DeviceProtocol.parseInfo(
          Uint8List.fromList([0x20, 0x02, 0x01, 0x02, 0x03]),
        ),
        throwsA(isA<DeviceProtocolException>()),
      );
      expect(
        () => DeviceProtocol.parseInfo(
          Uint8List.fromList([0x21, 0x01, 0x01, 0x02, 0x03]),
        ),
        throwsA(isA<DeviceProtocolException>()),
      );
      expect(
        () => DeviceProtocol.parseInfo(Uint8List(4)),
        throwsA(isA<DeviceProtocolException>()),
      );
      expect(
        () => DeviceProtocol.parseInfo(Uint8List(6)),
        throwsA(isA<DeviceProtocolException>()),
      );
    });
  });
}

Uint8List _validStatus() => Uint8List.fromList([
  0x20, 0x02, 0x00, 0x64, 0x01, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
]);
