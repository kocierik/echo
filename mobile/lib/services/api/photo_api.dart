import 'package:http/http.dart' as http;

import '../../models/photo.dart';
import 'api_client.dart';

/// The wearable camera: requests, uploads and images. Its TAKE_PHOTO commands come
/// with the others (device_api.dart).
abstract interface class PhotoApi {
  /// The app's camera button; the question (if any) and the answer go to
  /// [chatSessionId], or to "Voice requests". [fromWearableButton]: taken with the
  /// wearable's own button, so the answer is notified.
  Future<PhotoInfo> requestPhoto({
    String? question,
    String? chatSessionId,
    bool fromWearableButton = false,
    String source = 'app',
  });

  Future<PhotoInfo> getPhoto(String id);

  Future<void> uploadPhoto(String id, List<int> jpeg, DateTime capturedAt);

  /// [reason]: "muted", "not_connected", "no_camera", "capture_failed" or "busy".
  Future<void> reportPhotoFailure(String id, String reason);

  Future<PhotoImageSource> photoImage(String id);
}

/// A follow-up about a photo already answered ("Translate it", "Ask more"): the
/// server asks the vision model about the same image; the answer is returned and
/// added to the photo's chat.
abstract interface class PhotoFollowUpApi {
  Future<String> askAboutPhoto(String photoId, String question);
}

mixin PhotoEndpoints on ApiClient implements PhotoApi, PhotoFollowUpApi {
  @override
  Future<String> askAboutPhoto(String photoId, String question) async {
    final response = await post(
      '/api/photos/$photoId/ask',
      body: {'question': question},
      timeout: queryTimeout,
    );
    return parse(
      response.data,
      (data) => ((data as Map<String, dynamic>)['answer'] as String?) ?? '',
    );
  }

  @override
  Future<PhotoInfo> requestPhoto({
    String? question,
    String? chatSessionId,
    bool fromWearableButton = false,
    String source = 'app',
  }) async {
    final trimmed = question?.trim() ?? '';
    final from = fromWearableButton ? 'button' : source;
    final response = await post(
      '/api/photos',
      body: {
        if (from != 'app') 'source': from,
        if (trimmed.isNotEmpty) 'question': trimmed,
        if (chatSessionId != null) 'chat_session_id': chatSessionId,
      },
      expect: const {201},
    );
    return parse(
      response.data,
      (data) => PhotoInfo.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<PhotoInfo> getPhoto(String id) async {
    final response = await getCached('/api/photos/$id');
    return parse(
      response.data,
      (data) => PhotoInfo.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> uploadPhoto(String id, List<int> jpeg, DateTime capturedAt) async {
    final request = (await multipart('PUT', '/api/photos/$id/image'))
      ..headers['X-Captured-At'] = capturedAt.toUtc().toIso8601String()
      ..files.add(http.MultipartFile.fromBytes('image', jpeg, filename: 'photo.jpg'));
    final response = await upload(request);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw statusException(response.statusCode, response.body);
    }
  }

  @override
  Future<void> reportPhotoFailure(String id, String reason) async {
    await post(
      '/api/photos/$id/failure',
      body: {'reason': reason},
      decode: false,
    );
  }

  @override
  Future<PhotoImageSource> photoImage(String id) async {
    final headers = await credentials.headers;
    return PhotoImageSource(
      url: await url('/api/photos/$id/image'),
      headers: {'X-API-Key': headers['X-API-Key'] ?? ''},
    );
  }
}
