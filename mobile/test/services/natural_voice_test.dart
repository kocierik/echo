import 'dart:async';
import 'dart:typed_data';

import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/speech_api.dart';
import 'package:echo_app/services/app/spoken_voice_store.dart';
import 'package:echo_app/services/phone/answer_speaker.dart';
import 'package:echo_app/services/phone/natural_voice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Api implements SpeechApi {
  final asked = <(String, String)>[];
  ApiException? refuse;
  Completer<void>? gate;

  @override
  Future<Uint8List> speak(String text, String voice, {String? language}) async {
    asked.add((text, voice));
    await gate?.future;
    if (refuse != null) throw refuse!;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<({List<NaturalVoiceInfo> voices, bool available})> naturalVoices() async =>
      (voices: const <NaturalVoiceInfo>[], available: true);
}

final class _Phone implements AnswerVoice {
  final said = <String>[];
  int stops = 0;

  @override
  Future<void> speak(String text, String language) async => said.add(text);

  @override
  Future<void> stop() async => stops++;
}

final class _Playback implements AudioPlayback {
  final played = <Uint8List>[];
  int stops = 0;

  @override
  Future<void> play(Uint8List mp3) async => played.add(mp3);

  @override
  Future<void> stop() async => stops++;
}

Future<SpokenVoiceStore> _store({bool premium = true, String? natural}) async {
  SharedPreferences.setMockInitialValues({});
  final store = SpokenVoiceStore(await SharedPreferences.getInstance());
  await store.setPremium(premium);
  if (natural != null) await store.chooseNatural(natural);
  return store;
}

void main() {
  test('a natural voice chosen on Plus: the server\'s audio, played', () async {
    final api = _Api();
    final phone = _Phone();
    final playback = _Playback();
    final voice = NaturalVoice(
      api: api,
      phone: phone,
      store: await _store(natural: 'nova'),
      playback: playback,
    );

    await voice.speak('Domani hai il dentista.', 'it');

    expect(api.asked, [('Domani hai il dentista.', 'nova')]);
    expect(playback.played.single, [1, 2, 3]);
    expect(phone.said, isEmpty);
  });

  test('none chosen, or without Plus: the phone\'s voice, no request', () async {
    for (final store in [
      await _store(),
      await _store(premium: false, natural: 'nova'),
    ]) {
      final api = _Api();
      final phone = _Phone();
      final voice = NaturalVoice(api: api, phone: phone, store: store, playback: _Playback());

      await voice.speak('Ciao.', 'it');

      expect(api.asked, isEmpty);
      expect(phone.said, ['Ciao.']);
    }
  });

  test('offline or refused: the phone reads it, never lost', () async {
    final api = _Api()
      ..refuse = const ApiException(
        statusCode: 403,
        code: 'forbidden',
        message: 'Echo’s natural voices come with the Plus plan.',
        retryable: false,
      );
    final phone = _Phone();
    final playback = _Playback();
    final voice = NaturalVoice(
      api: api,
      phone: phone,
      store: await _store(natural: 'nova'),
      playback: playback,
    );

    await voice.speak('Ciao.', 'it');

    expect(phone.said, ['Ciao.']);
    expect(playback.played, isEmpty);
  });

  test('stopped while the audio is on its way: nothing is played', () async {
    final api = _Api()..gate = Completer<void>();
    final phone = _Phone();
    final playback = _Playback();
    final voice = NaturalVoice(
      api: api,
      phone: phone,
      store: await _store(natural: 'nova'),
      playback: playback,
    );

    final speaking = voice.speak('Ciao.', 'it');
    await voice.stop();
    api.gate!.complete();
    await speaking;

    expect(playback.played, isEmpty);
    expect(phone.said, isEmpty);
    expect((playback.stops, phone.stops), (1, 1));
  });

  test('without Plus the phone\'s own voice: no choice is used', () async {
    final store = await _store(premium: false);
    await store.choose('it', const PhoneVoice(name: 'Federica', locale: 'it-IT'));

    expect(store.voiceFor('it'), isNull);
    await store.setPremium(true);
    expect(store.voiceFor('it')?.name, 'Federica');
  });
}
