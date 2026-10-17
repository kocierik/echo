import 'package:echo_app/services/chat/voice_input.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  test('dictation listens in the language the user speaks', () async {
    final speech = _Speech([stt.LocaleName('en_US', 'English'), stt.LocaleName('it_IT', 'Italiano')]);
    final input = SpeechToTextVoiceInput(speech: speech);
    await input.available();

    await input.start(onPartial: (_) {}, onFinal: (_) {}, language: 'it');

    expect(speech.localeIds, ['it_IT']);
  });

  test('a language the phone cannot dictate falls back to the phone default', () async {
    final speech = _Speech([stt.LocaleName('en_US', 'English')]);
    final input = SpeechToTextVoiceInput(speech: speech);
    await input.available();

    await input.start(onPartial: (_) {}, onFinal: (_) {}, language: 'it');
    await input.start(onPartial: (_) {}, onFinal: (_) {});

    expect(speech.localeIds, [null, null]);
  });
}

final class _Speech implements stt.SpeechToText {
  _Speech(this._locales);

  final List<stt.LocaleName> _locales;
  final localeIds = <String?>[];

  @override
  Future<bool> initialize({
    dynamic onError,
    dynamic onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(milliseconds: 2000),
    List<stt.SpeechConfigOption>? options,
  }) async =>
      true;

  @override
  Future<List<stt.LocaleName>> locales() async => _locales;

  @override
  Future<void> listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    dynamic onSoundLevelChange,
    dynamic cancelOnError = false,
    dynamic partialResults = true,
    dynamic onDevice = false,
    dynamic listenMode = stt.ListenMode.confirmation,
    dynamic sampleRate = 0,
    stt.SpeechListenOptions? listenOptions,
  }) async {
    localeIds.add(listenOptions?.localeId ?? localeId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef SpeechResultListener = void Function(SpeechRecognitionResult result);
