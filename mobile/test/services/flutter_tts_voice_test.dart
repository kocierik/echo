import 'dart:async';

import 'package:echo_app/services/app/spoken_voice_store.dart';
import 'package:echo_app/services/phone/answer_speaker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

final class _Tts extends FlutterTts {
  _Tts({this.result = 1, this.hangLanguage = false});

  final int result;
  final bool hangLanguage;
  int stops = 0;
  final focused = <bool>[];

  @override
  Future<dynamic> setLanguage(String language) =>
      hangLanguage ? Completer<dynamic>().future : Future.value(1);

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    focused.add(focus);
    return result;
  }

  @override
  Future<dynamic> stop() async {
    stops++;
    return 1;
  }

  final calls = <String>[];

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    calls.add('voice ${voice['name']} ${voice['locale']}');
    return 1;
  }

  List<Object?> installed = const [];

  @override
  Future<dynamic> get getVoices async => installed;
}

void main() {
  testWidgets('an engine that refuses to speak ends the answer at once', (tester) async {
    var done = false;
    unawaited(FlutterTtsVoice(_Tts(result: 0)).speak('Domani piove.', 'it').then((_) => done = true));
    await tester.pump();

    expect(done, isTrue);
  });

  testWidgets('a platform call that never answers still ends the answer, and stops the voice',
      (tester) async {
    final tts = _Tts(hangLanguage: true);
    var done = false;
    unawaited(FlutterTtsVoice(tts).speak('Domani piove.', 'it').then((_) => done = true));
    await tester.pump(const Duration(minutes: 2));

    expect(done, isTrue);
    expect(tts.stops, 1);
  });

  testWidgets('on Android other sound is lowered while it speaks', (tester) async {
    final tts = _Tts(result: 0);

    await FlutterTtsVoice(tts).speak('Domani piove.', 'it');

    // flutter_tts asks Android for audio focus "may duck", released when it is done
    expect(tts.focused, [true]);
  });

  testWidgets("a stopped answer's late cancel does not end the next one", (tester) async {
    final tts = _Tts();
    final voice = FlutterTtsVoice(tts);
    var first = false;
    var second = false;
    unawaited(voice.speak('Prima.', 'it').then((_) => first = true));
    await tester.pump();

    await voice.stop();
    await tester.pump();
    expect(first, isTrue);

    unawaited(voice.speak('Seconda.', 'it').then((_) => second = true));
    await tester.pump();
    // The engine reports the first answer's cancel only now
    tts.cancelHandler!();
    await tester.pump();
    expect(second, isFalse);

    tts.completionHandler!();
    await tester.pump();
    expect(second, isTrue);
  });

  testWidgets('the voice chosen for the language speaks, the phone\'s for the others',
      (tester) async {
    final tts = _Tts(result: 0);
    final voice = FlutterTtsVoice(
      tts,
      (language) => language == 'it' ? const PhoneVoice(name: 'Federica', locale: 'it-IT') : null,
    );

    await voice.speak('Domani piove.', 'it');
    await voice.speak('It rains tomorrow.', 'en');

    expect(tts.calls, ['voice Federica it-IT']);
  });

  test("the language's voices, premium and enhanced first", () async {
    final tts = _Tts()
      ..installed = [
        {'name': 'Alice', 'locale': 'it-IT', 'quality': 'default'},
        {'name': 'Samantha', 'locale': 'en-US', 'quality': 'default'},
        {'name': 'Federica', 'locale': 'it-IT', 'quality': 'premium'},
        {'name': 'Luca', 'locale': 'it-IT', 'quality': 'enhanced'},
        {'locale': 'it-IT'},
        'not a voice',
      ];

    final voices = await FlutterTtsVoice(tts).voices('it');

    expect(voices.map((v) => v.name), ['Federica', 'Luca', 'Alice']);
  });
}
