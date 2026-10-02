import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

abstract interface class VoiceInput {
  Future<bool> available();
  Future<bool> request();
  Future<void> start({
    required ValueChanged<String> onPartial,
    required ValueChanged<String> onFinal,
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
  }) async {
    if (!_available) return;
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
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}