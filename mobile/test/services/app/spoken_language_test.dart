import 'package:echo_app/services/app/session_controller.dart';
import 'package:echo_app/services/app/spoken_language.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _Account account;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account = _Account();
  });

  Future<SpokenLanguageStore> store() async =>
      SpokenLanguageStore(api: account, preferences: await SharedPreferences.getInstance());

  test('a saved language is used without asking the server', () async {
    SharedPreferences.setMockInitialValues({SpokenLanguageStore.key: 'it'});
    final languages = await store();

    expect(await languages.current(), 'it');
    expect(account.reads, 0);
  });

  test('without one, the account says it and it is kept', () async {
    account.language = 'it';
    final languages = await store();

    expect(await languages.current(), 'it');
    expect(await languages.current(), 'it');
    expect(account.reads, 1);
  });

  test('a server that cannot be reached gives no language', () async {
    account.failing = true;
    expect(await (await store()).current(), isNull);
  });

  test('choosing a language changes the account, then the phone', () async {
    final languages = await store();

    await languages.set('en');

    expect(account.changes, ['en']);
    expect(await languages.current(), 'en');
  });

  test('signing out forgets the language, the next account has its own', () async {
    SharedPreferences.setMockInitialValues({SpokenLanguageStore.key: 'it'});
    final preferences = await SharedPreferences.getInstance();

    await SharedPreferencesSessionCacheClearer(preferences).clear();

    expect(preferences.getString(SpokenLanguageStore.key), isNull);
  });

  test('a change the server refuses is not kept', () async {
    account.failing = true;
    final languages = await store();

    await expectLater(languages.set('en'), throwsA(anything));
    expect(languages.cached, isNull);
  });
}

final class _Account implements AccountApi {
  String language = 'en';
  bool failing = false;
  int reads = 0;
  final changes = <String>[];

  @override
  Future<AccountInfo> me() async {
    reads++;
    if (failing) throw Exception('offline');
    return AccountInfo(email: 'erik@example.com', language: language);
  }

  @override
  Future<AccountInfo> setName(String? name) async =>
      AccountInfo(email: 'e@x.y', language: 'en', name: name);

  @override
  Future<AccountInfo> setLanguage(String language) async {
    if (failing) throw Exception('offline');
    changes.add(language);
    this.language = language;
    return AccountInfo(email: 'erik@example.com', language: language);
  }
}
