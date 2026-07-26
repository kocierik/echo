import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Wraps native speech recognition (on-device STT via iOS/Android).
class SpeechService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;

  Future<void> init() async {
    _initialized = await _speech.initialize(
      onError: (error) => print('[Speech] Error: ${error.errorMsg}'),
    );
  }

  Future<void> startListening(Function(String) onResult) async {
    if (!_initialized) {
      await init();
    }
    if (!_initialized) return;

    await _speech.listen(
      onResult: (result) {
        onResult(result.recognizedWords);
      },
      listenMode: stt.ListenMode.dictation,
      localeId: 'it_IT', // Italian primary, falls back to device locale
      cancelOnError: false,
      partialResults: true,
    );
  }

  Future<void> stopListening() async {
    await _speech.stop();
  }

  void dispose() {
    _speech.cancel();
  }
}
