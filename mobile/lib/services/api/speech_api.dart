import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';

/// One of Echo's natural voices: its name and what it sounds like.
typedef NaturalVoiceInfo = ({String id, String description});

/// Spoken answers in Echo's natural voices (POST /api/speech), on the plans that have them.
abstract interface class SpeechApi {
  /// The answer as MP3 in [voice], spoken as a native of [language] ("it", "en"); an
  /// [ApiException] (403) on a plan without them.
  Future<Uint8List> speak(String text, String voice, {String? language});

  /// The natural voices, and whether this account may use them.
  Future<({List<NaturalVoiceInfo> voices, bool available})> naturalVoices();
}

mixin SpeechEndpoints on ApiClient implements SpeechApi {
  @override
  Future<Uint8List> speak(String text, String voice, {String? language}) async {
    final target = await url('/api/speech');
    final headers = {...await credentials.headers, 'Content-Type': 'application/json'};
    final response = await guard(
      () => httpClient
          .post(
            target,
            headers: headers,
            body: jsonEncode({
              'text': text,
              'voice': voice,
              if (language != null) 'language': language,
            }),
          )
          .timeout(const Duration(seconds: 20)),
    );
    if (response.statusCode != 200) throw statusException(response.statusCode, response.body);
    return response.bodyBytes;
  }

  @override
  Future<({List<NaturalVoiceInfo> voices, bool available})> naturalVoices() async {
    final response = await get('/api/speech/voices');
    return parse(response.data, (data) {
      final json = data as Map<String, dynamic>;
      return (
        voices: [
          for (final item in json['voices'] as List<dynamic>)
            if (item is Map<String, dynamic>)
              (id: item['id'] as String, description: item['description'] as String? ?? ''),
        ],
        available: json['available'] as bool? ?? false,
      );
    });
  }
}
