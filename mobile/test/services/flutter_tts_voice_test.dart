import 'dart:async';

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
}
