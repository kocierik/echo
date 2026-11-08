import 'package:echo_app/screens/settings/language_settings_screen.dart';
import 'package:echo_app/screens/settings/voice_settings_screen.dart';
import 'package:echo_app/services/app/spoken_language.dart';
import 'package:echo_app/theme/app_theme.dart';
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
