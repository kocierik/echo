import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

abstract interface class VoiceInput {
  Future<bool> available();
  Future<bool> request();
  /// [language] ("it", "en"): the language the user speaks; without it, the phone's.
  Future<void> start({
    required ValueChanged<String> onPartial,
    required ValueChanged<String> onFinal,
    String? language,
  });
  Future<void> stop();
  Future<void> cancel();
}

final class SpeechToTextVoiceInput implements VoiceInput {
  SpeechToTextVoiceInput({stt.SpeechToText? speech})
      : _speech = speech ?? stt.SpeechToText();

  final stt.SpeechToText _speech;
  bool _initialized = false;
  bool _available = false;

  @override
  Future<bool> available() async {
    if (_initialized) return _available;
    _initialized = true;
    try {
      _available = await _speech.initialize(
        onError: (error) =>
            debugPrint('[Speech] Error: ${error.errorMsg}'),
      );
    } catch (error) {
      debugPrint('[Speech] Not available: $error');
      _available = false;
    }
    return _available;
  }

  @override
  Future<bool> request() async {
    if (!_initialized) await available();
    return _available;
  }

  @override
  Future<void> start({
    required ValueChanged<String> onPartial,
    required ValueChanged<String> onFinal,
    String? language,
  }) async {
    if (!_available) return;
    final localeId = language == null ? null : await _localeFor(language);
    await _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          onFinal(result.recognizedWords);
        } else {
          onPartial(result.recognizedWords);
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
        localeId: localeId,
      ),
    );
  }

  /// The phone's first dictation locale for [language] ("it" → "it_IT"), if any.
  Future<String?> _localeFor(String language) async {
    try {
      for (final locale in await _speech.locales()) {
        final id = locale.localeId.toLowerCase();
        if (id == language || id.startsWith('${language}_') || id.startsWith('$language-')) {
          return locale.localeId;
        }
      }
    } catch (error) {
      debugPrint('[Speech] No locales: $error');
    }
    return null;
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}