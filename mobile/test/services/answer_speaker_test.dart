import 'dart:async';

import 'package:echo_app/services/app/spoken_answers_store.dart';
import 'package:echo_app/services/phone/answer_speaker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Voice implements AnswerVoice {
  final said = <(String, String)>[];
  final log = <String>[];
  int stops = 0;
  bool fail = false;

  /// When set, speaking waits for it: an answer still being spoken.
  Completer<void>? hold;

  @override
  Future<void> speak(String text, String language) async {
    log.add('speak $text');
    if (fail) throw StateError('no engine');
    said.add((text, language));
    await hold?.future;
    log.add('done $text');
  }

  @override
  Future<void> stop() async {
    stops++;
    final waiting = hold;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }
}

final class _Output implements AudioOutput {
  bool on = false;

  @override
  Future<bool> headphones() async => on;
}

final class _Mic implements EchoMic {
  _Mic(this.log);

  final List<String> log;
  @override
  bool listening = true;
  bool failUnmute = false;

  @override
  Future<void> setMuted(bool muted) async {
    if (!muted && failUnmute) throw StateError('not connected');
    log.add(muted ? 'mute' : 'unmute');
    listening = !muted;
  }
}

void main() {
  late _Voice voice;
  late _Output output;
  late _Mic mic;
  late ValueNotifier<SpokenAnswers> setting;
  late SharedPreferences preferences;
  late String language;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    voice = _Voice();
    output = _Output();
    mic = _Mic(voice.log);
    setting = ValueNotifier(SpokenAnswers.always);
    language = 'it';
  });

  AnswerSpeaker speaker() => AnswerSpeaker(
        voice: voice,
        output: output,
        setting: setting,
        preferences: preferences,
        language: () => language,
        mic: mic,
      );

  test('off: nothing is spoken', () async {
    setting.value = SpokenAnswers.off;

    await speaker().say('Domani piove.');

    expect(voice.said, isEmpty);
  });

  test('headphones only: silent on the speaker, spoken in headphones', () async {
    setting.value = SpokenAnswers.headphones;
    final echo = speaker();

    await echo.say('Domani piove.');
    expect(voice.said, isEmpty);

    output.on = true;
    await echo.say('**Domani** piove.');
    expect(voice.said, [('Domani piove.', 'it')]);
    // In headphones Echo cannot hear it: never muted
    expect(voice.log.where((e) => e.contains('mute')), isEmpty);
  });

  test('on the speaker Echo is muted while the phone speaks, then listens again', () async {
    voice.hold = Completer();
    final speaking = speaker().say('Domani piove.');
    await pumpEventQueue();

    expect(voice.log, ['mute', 'speak Domani piove.']);
    expect(preferences.getBool(AnswerSpeaker.mutedKey), isTrue);

    voice.hold!.complete();
    await speaking;

    expect(voice.log, ['mute', 'speak Domani piove.', 'done Domani piove.', 'unmute']);
    expect(preferences.getBool(AnswerSpeaker.mutedKey), isNull);
  });

  test('Echo muted by the user stays muted', () async {
    mic.listening = false;

    await speaker().say('Domani piove.');

    expect(voice.log, ['speak Domani piove.', 'done Domani piove.']);
  });

  test('two answers are spoken one after the other, in order', () async {
    voice.hold = Completer();
    final echo = speaker();
    final first = echo.say('Prima.');
    final second = echo.say('Seconda.');
    await pumpEventQueue();

    expect(voice.said.map((s) => s.$1), ['Prima.']);

    voice.hold!.complete();
    await Future.wait([first, second]);

    expect(voice.said.map((s) => s.$1), ['Prima.', 'Seconda.']);
    expect(
      voice.log.indexOf('done Prima.'),
      lessThan(voice.log.indexOf('speak Seconda.')),
    );
  });

  test('stop ends the answer and drops the ones waiting', () async {
    voice.hold = Completer();
    final echo = speaker();
    final first = echo.say('Prima.');
    final second = echo.say('Seconda.');
    await pumpEventQueue();

    await echo.stop();
    await Future.wait([first, second]);

    expect(voice.stops, 1);
    expect(voice.said.map((s) => s.$1), ['Prima.']);
    expect(mic.listening, isTrue);

    // A new answer after stop is spoken
    await echo.say('Terza.');
    expect(voice.said.map((s) => s.$1), ['Prima.', 'Terza.']);
  });

  test('a failing voice leaves Echo listening and never throws', () async {
    voice.fail = true;
    final echo = speaker();

    await echo.say('Domani piove.');

    expect(mic.listening, isTrue);
    expect(preferences.getBool(AnswerSpeaker.mutedKey), isNull);
    voice.fail = false;
    await echo.say('Ancora.');
    expect(voice.said.map((s) => s.$1), ['Ancora.']);
  });

  test('recover unmutes Echo left muted by an answer; keeps trying when it cannot', () async {
    await preferences.setBool(AnswerSpeaker.mutedKey, true);
    mic.listening = false;
    mic.failUnmute = true;
    final echo = speaker();

    await echo.recover();
    expect(preferences.getBool(AnswerSpeaker.mutedKey), isTrue);

    mic.failUnmute = false;
    await echo.recover();
    expect(mic.listening, isTrue);
    expect(preferences.getBool(AnswerSpeaker.mutedKey), isNull);
  });

  test('recover while an answer is spoken leaves Echo muted until it ends', () async {
    voice.hold = Completer();
    final echo = speaker();
    final speaking = echo.say('Domani piove.');
    await pumpEventQueue();

    await echo.recover();
    expect(mic.listening, isFalse);

    voice.hold!.complete();
    await speaking;
    expect(mic.listening, isTrue);
  });

  test('recover leaves Echo alone without the flag', () async {
    mic.listening = false;

    await speaker().recover();

    expect(mic.listening, isFalse);
  });

  test('Try it speaks a sample in the language even when off', () async {
    setting.value = SpokenAnswers.off;
    language = 'en';

    await speaker().sample();

    expect(voice.said.single.$2, 'en');
    expect(voice.said.single.$1, isNotEmpty);
  });
}
