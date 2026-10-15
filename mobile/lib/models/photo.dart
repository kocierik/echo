import 'package:flutter/foundation.dart';

/// A photo from the wearable camera, as the backend tracks it.
@immutable
final class PhotoInfo {
  const PhotoInfo({
    required this.id,
    required this.status,
    this.answer,
    this.error,
    this.chatSessionId,
  });

  final String id;

  /// "requested", "received", "done" or "failed".
  final String status;
  final String? answer;
  final String? error;

  /// The chat its answer goes to.
  final String? chatSessionId;

  bool get isFinished => status == 'done' || status == 'failed';

  factory PhotoInfo.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final status = json['status'];
    if (id is! String || status is! String) {
      throw const FormatException('photo needs an id and a status');
    }
    return PhotoInfo(
      id: id,
      status: status,
      answer: json['answer'] as String?,
      error: json['error'] as String?,
      chatSessionId: json['chat_session_id'] as String?,
    );
  }
}

/// Where the image of a photo is downloaded from (the API key goes in the headers).
@immutable
final class PhotoImageSource {
  const PhotoImageSource({required this.url, required this.headers});

  final Uri url;
  final Map<String, String> headers;
}
