import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Wraps native speech recognition (on-device STT via iOS/Android).
/// Falls back gracefully on unsupported platforms (Linux/Windows desktop).
class SpeechService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  bool _available = false;

  bool get isAvailable => _available;

  Future<void> init() async {
    try {
      _initialized = await _speech.initialize(
        onError: (error) => debugPrint('[Speech] Error: ${error.errorMsg}'),
      );
      _available = _initialized;
    } catch (e) {
      // Platform not supported (Linux desktop, etc.)
      debugPrint('[Speech] Not available on this platform: $e');
      _available = false;
    }
  }

  Future<void> startListening(Function(String) onResult) async {
    if (!_initialized) {
      await init();
    }
    if (!_available) return;

    await _speech.listen(
      onResult: (result) {
        onResult(result.recognizedWords);
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        localeId: 'it_IT',
        cancelOnError: false,
        partialResults: true,
      ),
    );
  }

  Future<void> stopListening() async {
    if (_available) {
      await _speech.stop();
    }
  }

  void dispose() {
    if (_available) {
      _speech.cancel();
    }
  }
}
