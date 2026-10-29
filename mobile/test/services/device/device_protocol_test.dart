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

    test('protocol 5 says whether a microSD is in use, its room and its speech', () {
      final status = DeviceProtocol.parseStatus(_v5Status(flags: 0x08));

      expect(status.microSd, isNotNull);
      expect(status.microSd!.inUse, isTrue);
      expect(status.microSd!.totalMb, 30436);
      expect(status.microSd!.freeMb, 29802);
      expect(status.microSd!.pendingKb, 5120);
      expect(DeviceProtocol.parseStatus(_v5Status(flags: 0x00)).microSd!.inUse, isFalse);
      // Older firmware cannot say
      expect(DeviceProtocol.parseStatus(_validStatus()).microSd, isNull);
      expect(
        () => DeviceProtocol.parseStatus(_v5Status(flags: 0x10)),
        throwsA(isA<DeviceProtocolException>()),
      );
      expect(
        () => DeviceProtocol.parseStatus(Uint8List.fromList(_validStatus()..[1] = 0x05)),
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

    test('protocol 4 status and info are read like protocol 3', () {
      final status = DeviceProtocol.parseStatus(_validStatus()..[1] = 4);
      expect(status.bufferCount, 1);
      final info = DeviceProtocol.parseInfo(
        Uint8List.fromList([0x21, 0x04, 0x00, 0x05, 0x00]),
      );
      expect(info.protocolVersion, DeviceProtocol.otaVersion);
      expect(info.firmwareMinor, 5);
    });

    test('accepts a wearable that checks signed updates (protocol 6)', () {
      final info = DeviceProtocol.parseInfo(
        Uint8List.fromList([0x21, 0x06, 0x00, 0x08, 0x00]),
      );
      expect(info.protocolVersion, DeviceProtocol.signedOtaVersion);
      expect(DeviceProtocol.parseStatus(_v5Status(flags: 0)..[1] = 6).muted, isFalse);
    });

    test('encodes the firmware update frames', () {
      final sha = List<int>.generate(32, (i) => i);
      final begin = DeviceProtocol.otaBegin(0x00091000, sha);
      expect(begin.sublist(0, 5), orderedEquals([0x19, 0x00, 0x10, 0x09, 0x00]));
      expect(begin.sublist(5), orderedEquals(sha));
      expect(() => DeviceProtocol.otaBegin(10, [1, 2]), throwsArgumentError);
      // Protocol 6: the release key's signature after the SHA-256
      final signature = List<int>.generate(64, (i) => 100 + i);
      final signed = DeviceProtocol.otaBegin(0x00091000, sha, signature: signature);
      expect(signed.length, 101);
      expect(signed.sublist(0, 37), orderedEquals(begin));
      expect(signed.sublist(37), orderedEquals(signature));
      expect(() => DeviceProtocol.otaBegin(10, sha, signature: [1]), throwsArgumentError);
      expect(DeviceProtocol.otaAbort(), orderedEquals([0x1A]));
      expect(
        DeviceProtocol.otaChunk(0x10, [0xAA, 0xBB]),
        orderedEquals([0x10, 0x00, 0x00, 0x00, 0xAA, 0xBB]),
      );
    });

    test('parses OTA_STATUS and ignores other frames', () {
      final failed = DeviceProtocol.parseOtaStatus(
        [0x23, 0x03, 0x06, 0x78, 0x56, 0x34, 0x12],
      )!;
      expect(failed.state, OtaState.failed);
      expect(failed.error, 6);
      expect(failed.received, 0x12345678);
      expect(
        DeviceProtocol.parseOtaStatus([0x23, 0x02, 0, 0, 0, 0, 0])!.state,
        OtaState.done,
      );
      expect(DeviceProtocol.parseOtaStatus([0x23, 0x09, 0, 0, 0, 0, 0]), isNull);
      expect(DeviceProtocol.parseOtaStatus([0x22, 0x01]), isNull);
      expect(DeviceProtocol.otaErrorMessage(6), contains('damaged'));
      expect(DeviceProtocol.otaErrorMessage(10), contains('not signed'));
    });
  });
}

Uint8List _v5Status({required int flags}) => Uint8List.fromList([
  0x20, 0x05, flags, 0x64, 0x01, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
  0xE4, 0x76, 0x00, 0x00, 0x6A, 0x74, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00,
]);

Uint8List _validStatus() => Uint8List.fromList([
  0x20, 0x02, 0x00, 0x64, 0x01, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
]);
