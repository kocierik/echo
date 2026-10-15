import 'dart:typed_data';

import 'package:echo_app/models/device_command.dart';
import 'package:echo_app/models/photo.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/device/photo_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakePhotoApi api;
  late _FakeDevice device;
  late PhotoService service;

  setUp(() {
    api = _FakePhotoApi();
    device = _FakeDevice();
    service = PhotoService(
      api: api,
      device: device,
      sleep: (_) async {},
    );
  });

  tearDown(() => service.dispose());

  group('the camera button', () {
    test('asks the backend, then the wearable', () async {
      final photo = await service.takePhoto(
          question: 'Che pianta è?', chatSessionId: 's1');

      expect(photo.id, 'p1');
      expect(api.requests, [('Che pianta è?', 's1')]);
      expect(device.takePhotos, 1);
      expect(service.pendingPhotoId, 'p1');
    });

    test('refuses when the wearable cannot take a photo now', () async {
      for (final (setup, reason) in [
        (() => device.connected = false, 'not_connected'),
        (() => device.muted = true, 'muted'),
        (() => device.cameraReady = false, 'no_camera'),
      ]) {
        device = _FakeDevice();
        service = PhotoService(api: api, device: device, sleep: (_) async {});
        setup();
        await expectLater(
          service.takePhoto(),
          throwsA(isA<PhotoUnavailableException>()
              .having((e) => e.reason, 'reason', reason)),
        );
      }
      expect(api.requests, isEmpty);
    });

    test('takes one photo at a time', () async {
      await service.takePhoto();
      await expectLater(
        service.takePhoto(),
        throwsA(isA<PhotoUnavailableException>()
            .having((e) => e.reason, 'reason', 'busy')),
      );
    });

    test('waits for the answer by polling the backend', () async {
      api.statuses = ['requested', 'received', 'done'];
      final photo = await service.waitForAnswer('p1');
      expect(photo.status, 'done');
      expect(api.gets, 3);
    });
  });

  group('the wearable', () {
    test('uploads the JPEG for the pending photo and frees it', () async {
      await service.takePhoto();
      final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff]);
      final at = DateTime.utc(2026, 10, 14, 20);

      expect(await service.uploadFromDevice(jpeg, at), isTrue);

      expect(api.uploads, [('p1', 3, at)]);
      expect(service.pendingPhotoId, isNull);
    });

    test('a photo from the wearable button (nobody waiting) reaches the chat',
        () async {
      await service.uploadFromDevice(
          Uint8List.fromList([1]), DateTime.utc(2026));

      expect(api.requests, [(null, null)]);
      expect(api.buttonRequests, [true]); // notified: the phone is not in view
      expect(api.uploads.single.$1, 'p1');
    });

    test('a failed upload throws, so the relay retries with the same photo',
        () async {
      await service.takePhoto();
      api.uploadError = Exception('offline');
      await expectLater(
        service.uploadFromDevice(Uint8List.fromList([1]), DateTime.utc(2026)),
        throwsException,
      );
      expect(service.pendingPhotoId, 'p1');
    });

    test('PHOTO_FAILED is reported for the pending photo', () async {
      await service.takePhoto();
      await service.onDeviceFailure('capture_failed');

      expect(api.failures, [('p1', 'capture_failed')]);
      expect(service.pendingPhotoId, isNull);
      await service
          .onDeviceFailure('busy'); // nothing pending: nothing to report
      expect(api.failures, hasLength(1));
    });

    test('a TAKE_PHOTO that cannot be written is reported as not connected',
        () async {
      device.writeError = Exception('BLE gone');
      await service.takePhoto();

      expect(api.failures, [('p1', 'not_connected')]);
      expect(service.pendingPhotoId, isNull);
    });
  });

  group('a voice request (TAKE_PHOTO from the commands)', () {
    test('goes to the wearable', () async {
      await service.handleTakePhoto(const TakePhotoCommand('v1'));

      expect(device.takePhotos, 1);
      expect(service.pendingPhotoId, 'v1');
    });

    test('is reported at once when the wearable cannot take it', () async {
      device.connected = false;

      await service.handleTakePhoto(const TakePhotoCommand('v1'));

      expect(device.takePhotos, 0);
      expect(api.failures, [('v1', 'not_connected')]);
    });

    test('waits for the photo already being taken', () async {
      await service.handleTakePhoto(const TakePhotoCommand('v1'));
      await service.handleTakePhoto(const TakePhotoCommand('v2'));

      expect(device.takePhotos, 1);
      expect(api.failures, [('v2', 'busy')]);
    });
  });
}

final class _FakeDevice implements PhotoDevice {
  @override
  bool cameraReady = true;
  @override
  bool connected = true;
  @override
  bool muted = false;
  int takePhotos = 0;
  Object? writeError;

  @override
  Future<void> sendTakePhoto() async {
    if (writeError != null) throw writeError!;
    takePhotos++;
  }
}

final class _FakePhotoApi implements PhotoApi {
  final requests = <(String?, String?)>[];
  final buttonRequests = <bool>[];
  final uploads = <(String, int, DateTime)>[];
  final failures = <(String, String)>[];
  List<String> statuses = ['done'];
  int gets = 0;
  Object? uploadError;

  @override
  Future<PhotoInfo> requestPhoto({
    String? question,
    String? chatSessionId,
    bool fromWearableButton = false,
  }) async {
    buttonRequests.add(fromWearableButton);
    requests.add((question, chatSessionId));
    return PhotoInfo(
        id: 'p${requests.length}',
        status: 'requested',
        chatSessionId: chatSessionId);
  }

  @override
  Future<PhotoInfo> getPhoto(String id) async {
    final status = statuses[gets.clamp(0, statuses.length - 1)];
    gets++;
    return PhotoInfo(id: id, status: status);
  }

  @override
  Future<void> uploadPhoto(
      String id, List<int> jpeg, DateTime capturedAt) async {
    if (uploadError != null) throw uploadError!;
    uploads.add((id, jpeg.length, capturedAt));
  }

  @override
  Future<void> reportPhotoFailure(String id, String reason) async {
    failures.add((id, reason));
  }

  @override
  Future<PhotoImageSource> photoImage(String id) async => PhotoImageSource(
      url: Uri.parse('https://echo.test/api/photos/$id/image'),
      headers: const {});
}
