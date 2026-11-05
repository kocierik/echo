import 'package:echo_app/screens/settings/spoken_answers_screen.dart';
import 'package:echo_app/services/app/spoken_answers_store.dart';
import 'package:echo_app/services/app/spoken_voice_store.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the three choices; a tap keeps it; Try it speaks', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SpokenAnswersStore(await SharedPreferences.getInstance());
    var tries = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: SpokenAnswersScreen(store: store, onTry: () async => tries++),
    ));

    for (final label in ['Off', 'Headphones', 'Always']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Headphones'));
    await tester.pumpAndSettle();
    expect(store.value, SpokenAnswers.headphones);

    await tester.tap(find.byKey(const Key('spoken-answers-try')));
    await tester.pumpAndSettle();
    expect(tries, 1);
  });

  testWidgets('Voice: the phone\'s voices, better ones first; a tap keeps it and speaks',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final voiceStore = SpokenVoiceStore(preferences);
    var tries = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: SpokenAnswersScreen(
        store: SpokenAnswersStore(preferences),
        onTry: () async => tries++,
        voices: _Catalog(),
        voiceStore: voiceStore,
        language: 'it',
      ),
    ));
    expect(find.text("The phone's"), findsOneWidget);

    await tester.tap(find.byKey(const Key('spoken-answers-voice')));
    await tester.pumpAndSettle();
    expect(find.text('Premium · it-IT'), findsOneWidget);
    await tester.tap(find.text('Federica'));
    await tester.pumpAndSettle();

    expect(voiceStore.voiceFor('it'), const PhoneVoice(name: 'Federica', locale: 'it-IT'));
    expect(voiceStore.voiceFor('en'), isNull);
    expect(tries, 1);

    await tester.tap(find.byKey(const Key('voice-default')));
    await tester.pumpAndSettle();
    expect(voiceStore.voiceFor('it'), isNull);
    expect(tries, 2);
  });
}

final class _Catalog implements VoiceCatalog {
  @override
  Future<List<PhoneVoice>> voices(String language) async => const [
        PhoneVoice(name: 'Federica', locale: 'it-IT', quality: 'premium'),
        PhoneVoice(name: 'Alice', locale: 'it-IT'),
      ];
}
