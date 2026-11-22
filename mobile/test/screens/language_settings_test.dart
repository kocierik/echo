import 'package:echo_app/screens/settings/language_settings_screen.dart';
import 'package:echo_app/screens/settings/voice_settings_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/app/spoken_language.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/spoken_language_choice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('choosing Italiano changes the account and the dictation', (tester) async {
    SharedPreferences.setMockInitialValues({SpokenLanguageStore.key: 'en'});
    final account = _Account();
    final store =
        SpokenLanguageStore(api: account, preferences: await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: LanguageSettingsScreen(store: store),
    ));
    await tester.pumpAndSettle();

    expect(find.text('English'), findsOneWidget);
    await tester.tap(find.byKey(const Key('language-it')));
    await tester.pumpAndSettle();

    expect(account.changes, ['it']);
    expect(await store.current(), 'it');
  });

  testWidgets('a refused change says so and keeps the old language', (tester) async {
    SharedPreferences.setMockInitialValues({SpokenLanguageStore.key: 'en'});
    final account = _Account()..failing = true;
    final store =
        SpokenLanguageStore(api: account, preferences: await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: LanguageSettingsScreen(store: store),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('language-it')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not change the language'), findsOneWidget);
    expect(store.cached, 'en');
  });

  testWidgets('other languages heard: every one but the main, a tap keeps it', (tester) async {
    SharedPreferences.setMockInitialValues({SpokenLanguageStore.key: 'it'});
    final account = _Account()
      ..language = 'it'
      ..others = ['en'];
    final store =
        SpokenLanguageStore(api: account, preferences: await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: LanguageSettingsScreen(store: store),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('other-language-it')), findsNothing);
    expect(tester.widget<FilterChip>(find.byKey(const Key('other-language-en'))).selected,
        isTrue);
    await tester.ensureVisible(find.byKey(const Key('other-language-es')));
    await tester.tap(find.byKey(const Key('other-language-es')));
    await tester.pumpAndSettle();

    expect(account.otherChanges, [
      ['en', 'es'],
    ]);
    expect(tester.widget<FilterChip>(find.byKey(const Key('other-language-es'))).selected,
        isTrue);
  });

  testWidgets('a refused change of the other languages says so and keeps them',
      (tester) async {
    SharedPreferences.setMockInitialValues({SpokenLanguageStore.key: 'it'});
    final account = _Account()..language = 'it';
    final store =
        SpokenLanguageStore(api: account, preferences: await SharedPreferences.getInstance());
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: LanguageSettingsScreen(store: store),
    ));
    await tester.pumpAndSettle();
    account.failing = true;

    await tester.ensureVisible(find.byKey(const Key('other-language-es')));
    await tester.tap(find.byKey(const Key('other-language-es')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not change'), findsOneWidget);
    expect(tester.widget<FilterChip>(find.byKey(const Key('other-language-es'))).selected,
        isFalse);
  });

  testWidgets('before recording, the language can be chosen and the text follows it',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final account = _Account(); // a phone in English
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: VoiceEnrollmentScreen(
        api: _NoVoices(),
        language: 'en',
        languageStore: SpokenLanguageStore(api: account, preferences: preferences),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hi, this is my voice'), findsOneWidget);

    await tester.tap(find.text('Italiano'));
    await tester.pumpAndSettle();

    expect(account.changes, ['it']);
    expect(preferences.getString(SpokenLanguageStore.key), 'it');
    expect(find.textContaining('Ciao, questa è la mia voce'), findsOneWidget);
  });

  testWidgets('a language the server refuses goes back, and says why', (tester) async {
    SharedPreferences.setMockInitialValues({SpokenLanguageStore.key: 'en'});
    final preferences = await SharedPreferences.getInstance();
    final account = _Account()..failing = true;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SpokenLanguageChoice(
          store: SpokenLanguageStore(api: account, preferences: preferences),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Italiano'));
    await tester.pumpAndSettle();

    final choice = tester.widget<SegmentedButton<String>>(find.byKey(const Key('spoken-language')));
    expect(choice.selected, {'en'});
    expect(preferences.getString(SpokenLanguageStore.key), 'en');
    expect(find.textContaining('Could not change the language'), findsOneWidget);
  });

  test('the voice sample is in the language the user speaks', () {
    expect(enrollmentTextFor('it'), startsWith('Ciao, questa'));
    expect(enrollmentTextFor('en'), startsWith('Hi, this'));
    expect(enrollmentTextFor(null), startsWith('Hi, this'));
  });
}

final class _Account implements AccountApi {
  bool failing = false;
  String language = 'en';
  List<String> others = [];
  final changes = <String>[];
  final otherChanges = <List<String>>[];

  @override
  Future<AccountInfo> me() async =>
      AccountInfo(email: 'e@x.y', language: language, otherLanguages: others);

  @override
  Future<AccountInfo> setOtherLanguages(List<String> languages) async {
    if (failing) throw Exception('offline');
    otherChanges.add(languages);
    others = languages;
    return AccountInfo(email: 'e@x.y', language: language, otherLanguages: languages);
  }

  @override
  Future<AccountInfo> setLanguage(String language) async {
    if (failing) throw Exception('offline');
    changes.add(language);
    return AccountInfo(email: 'e@x.y', language: language);
  }
}

final class _NoVoices implements VoiceApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

