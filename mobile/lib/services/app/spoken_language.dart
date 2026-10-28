import 'package:shared_preferences/shared_preferences.dart';

/// The account as Profile sees it: its email, spoken language and name.
final class AccountInfo {
  const AccountInfo({
    required this.email,
    required this.language,
    this.name,
    this.instructions,
    this.otherLanguages = const [],
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) {
    String? text(String key) {
      final value = (json[key] as String?)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    return AccountInfo(
      email: json['email'] as String?,
      language: json['language'] as String? ?? 'en',
      name: text('name'),
      instructions: text('instructions'),
      otherLanguages: List.unmodifiable(
        (json['other_languages'] as List<dynamic>? ?? const []).whereType<String>(),
      ),
    );
  }

  /// Null for a key made on the server before any account.
  final String? email;
  final String language;

  /// What Today's greeting calls the user; null until they give one.
  final String? name;

  /// The user's own instructions to Echo (Profile → Instructions), used in every answer.
  final String? instructions;

  /// Other languages spoken around the user ("en", "es"): Echo recognises which one each
  /// segment is in, and the app can translate them.
  final List<String> otherLanguages;
}

abstract interface class AccountApi {
  Future<AccountInfo> me();
  Future<AccountInfo> setLanguage(String language);

  /// At most [maxOtherLanguages] of [heardLanguages], never the main language.
  Future<AccountInfo> setOtherLanguages(List<String> languages);
}

/// The user's own instructions to Echo ("Call me Erik, keep answers short").
abstract interface class InstructionsApi {
  /// Null (or blank) removes them.
  Future<AccountInfo> setInstructions(String? instructions);
}

/// The languages Echo transcribes and takes dictation in, as Settings names them.
const spokenLanguages = {'en': 'English', 'it': 'Italiano'};

/// The other languages Echo can recognise around the user, in their own names.
const heardLanguages = {
  'en': 'English',
  'it': 'Italiano',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'pt': 'Português',
};
const maxOtherLanguages = 4;

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

  /// The other languages the account hears; null when the server cannot say.
  Future<List<String>?> otherLanguages() async {
    try {
      return (await _api.me()).otherLanguages;
    } catch (_) {
      return null;
    }
  }

  /// Saves them; the account's list as kept. Throws when the server refuses.
  Future<List<String>> setOtherLanguages(List<String> languages) async =>
      (await _api.setOtherLanguages(languages)).otherLanguages;
}
