import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../device/firmware_update.dart';
import 'api_client.dart';

/// What the wearable sends and gets through the phone: audio segments and firmware.
mixin WearableEndpoints on ApiClient implements FirmwareApi {
  /// Uploads an audio segment from the wearable (used by the BLE relay).
  Future<bool> uploadSegment({
    required List<int> audioData,
    required String recordedAt,
    required int durationMs,
    int? silenceBeforeMs,
    int? audioEnergy,
    bool wakeHeard = false,
  }) async {
    final request = await multipart('POST', '/api/segments');
    debugPrint(
      '[API] uploadSegment start uri=${request.url} recordedAt=$recordedAt '
      'durationMs=$durationMs audioBytes=${audioData.length}',
    );
    request.headers['X-Recorded-At'] = recordedAt;
    request.headers['X-Duration-Ms'] = durationMs.toString();
    if (silenceBeforeMs != null) {
      request.headers['X-Silence-Before-Ms'] = silenceBeforeMs.toString();
    }
    if (audioEnergy != null) {
      request.headers['X-Audio-Energy'] = audioEnergy.toString();
    }
    if (wakeHeard) request.headers['X-Wake-Heard'] = '1';
    request.files.add(
      http.MultipartFile.fromBytes('audio', audioData, filename: 'segment.adpcm'),
    );

    final response = await upload(request);
    debugPrint('[API] uploadSegment response status=${response.statusCode}');
    if (response.statusCode != 201) {
      throw statusException(response.statusCode, response.body);
    }
    return true;
  }

  /// Not cached: an offer read offline could be one the server no longer makes.
  @override
  Future<FirmwareRelease?> latestFirmware() async {
    final response = await get('/api/firmware/latest');
    return parse(response.data, (data) {
      final firmware = (data as Map<String, dynamic>)['firmware'];
      return firmware == null
          ? null
          : FirmwareRelease.fromJson(firmware as Map<String, dynamic>);
    });
  }

  @override
  Future<Uint8List> downloadFirmware(String version) =>
      getBytes('/api/firmware/${Uri.encodeComponent(version)}/image');
}
