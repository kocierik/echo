import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A voice installed on the phone, as its text-to-speech lists it.
@immutable
final class PhoneVoice {
  const PhoneVoice({required this.name, required this.locale, this.quality = 'default'});

  /// From the plugin's voice map ({name, locale, quality, …}); null without name or locale.
  static PhoneVoice? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final locale = raw['locale'];
    if (name is! String || locale is! String || name.isEmpty || locale.isEmpty) return null;
    final quality = raw['quality'];
    return PhoneVoice(
      name: name,
      locale: locale,
      quality: quality is String && quality.isNotEmpty ? quality : 'default',
    );
  }

  final String name;

  /// "it-IT", "en-GB"…
  final String locale;

  /// iOS: "default" (compact), "enhanced" or "premium" (downloaded in Settings).
  final String quality;

  /// Better voices first.
  int get rank => switch (quality) {
        'premium' => 0,
        'enhanced' => 1,
        _ => 2,
      };

  /// "Premium · it-IT".
  String get detail => switch (quality) {
        'premium' => 'Premium · $locale',
        'enhanced' => 'Enhanced · $locale',
        _ => locale,
      };

  Map<String, String> toTts() => {'name': name, 'locale': locale};

  @override
  bool operator ==(Object other) =>
      other is PhoneVoice && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

/// The voices the phone has for a language ("it", "en"), better ones first.
abstract interface class VoiceCatalog {
  Future<List<PhoneVoice>> voices(String language);
}

/// Profile → Spoken answers → Voice: the voice chosen for each language, kept on this
/// phone; none is the phone's own for the language.
final class SpokenVoiceStore extends ChangeNotifier {
  SpokenVoiceStore(this._preferences);

  final SharedPreferences _preferences;

  static String keyFor(String language) => 'spoken_voice_$language';

  PhoneVoice? voiceFor(String language) {
    final stored = _preferences.getString(keyFor(language));
    if (stored == null) return null;
    try {
      return PhoneVoice.fromMap(jsonDecode(stored));
    } catch (_) {
      return null;
    }
  }

  Future<void> choose(String language, PhoneVoice? voice) async {
    if (voice == null) {
      await _preferences.remove(keyFor(language));
    } else {
      await _preferences.setString(
        keyFor(language),
        jsonEncode({'name': voice.name, 'locale': voice.locale, 'quality': voice.quality}),
      );
    }
    notifyListeners();
  }
}
