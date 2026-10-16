import 'package:shared_preferences/shared_preferences.dart';

/// The account as Settings → Language sees it.
final class AccountInfo {
  const AccountInfo({required this.email, required this.language});

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
        email: json['email'] as String?,
        language: json['language'] as String? ?? 'en',
      );

  /// Null for a key made on the server before any account.
  final String? email;
  final String language;
}

abstract interface class AccountApi {
  Future<AccountInfo> me();
  Future<AccountInfo> setLanguage(String language);
}

/// The languages Echo transcribes and takes dictation in, as Settings names them.
const spokenLanguages = {'en': 'English', 'it': 'Italiano'};

/// The language the user speaks: the account's (the wearable's transcription), kept on
/// the phone for dictation so holding the Ask button never waits for the server.
final class SpokenLanguageStore {
  SpokenLanguageStore({required AccountApi api, required SharedPreferences preferences})
      : _api = api,
        _preferences = preferences;

  static const key = 'spoken_language';

  final AccountApi _api;
  final SharedPreferences _preferences;

  /// What this phone knows, without asking.
  String? get cached => _preferences.getString(key);

  /// The saved language, else the account's (then saved); null if unknown.
  Future<String?> current() async {
    final saved = cached;
    if (saved != null) return saved;
    try {
      final language = (await _api.me()).language;
      await _preferences.setString(key, language);
      return language;
    } catch (_) {
      return null;
    }
  }

  /// Changes the account's language, then this phone's; throws when the server refuses.
  Future<void> set(String language) async {
    final changed = await _api.setLanguage(language);
    await _preferences.setString(key, changed.language);
  }
}
