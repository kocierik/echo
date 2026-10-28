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
    await tester.tap(find.text('Italiano'));
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

    await tester.tap(find.text('Italiano'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not change the language'), findsOneWidget);
    expect(store.cached, 'en');
  });

  test('the voice sample is in the language the user speaks', () {
    expect(enrollmentTextFor('it'), startsWith('Ciao Echo'));
    expect(enrollmentTextFor('en'), startsWith('Hi Echo'));
    expect(enrollmentTextFor(null), startsWith('Hi Echo'));
  });
}

final class _Account implements AccountApi {
  bool failing = false;
  final changes = <String>[];

  @override
  Future<AccountInfo> me() async => const AccountInfo(email: 'e@x.y', language: 'en');

  @override
  Future<AccountInfo> setLanguage(String language) async {
    if (failing) throw Exception('offline');
    changes.add(language);
    return AccountInfo(email: 'e@x.y', language: language);
  }
}
