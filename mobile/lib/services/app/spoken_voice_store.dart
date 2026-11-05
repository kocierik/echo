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

/// Profile → Spoken answers → Voice, kept on this phone. On the plans with natural voices
/// (Plus, Unlimited: [premium], from the server's plan): one of Echo's natural voices, or
/// one of the phone's for each language. On the others: the phone's own voice for the
/// language, no choice.
final class SpokenVoiceStore extends ChangeNotifier {
  SpokenVoiceStore(this._preferences);

  final SharedPreferences _preferences;

  static String keyFor(String language) => 'spoken_voice_$language';
  static const naturalKey = 'spoken_voice_natural';
  static const premiumKey = 'spoken_voice_premium';

  /// The plan has Echo's natural voices (and the choice of a voice at all).
  bool get premium => _preferences.getBool(premiumKey) ?? false;

  /// From the plan, when it is read (Profile).
  Future<void> setPremium(bool value) async {
    if (value == premium) return;
    await _preferences.setBool(premiumKey, value);
    notifyListeners();
  }

  /// Echo's natural voice chosen ("coral"), on a plan that has them.
  String? get naturalVoice => premium ? _preferences.getString(naturalKey) : null;

  /// One of Echo's natural voices; none: the phone's.
  Future<void> chooseNatural(String? id) async {
    if (id == null) {
      await _preferences.remove(naturalKey);
    } else {
      await _preferences.setString(naturalKey, id);
    }
    notifyListeners();
  }

  /// The phone's voice chosen for [language]; none (the phone's own) without the plan.
  PhoneVoice? voiceFor(String language) {
    if (!premium) return null;
    final stored = _preferences.getString(keyFor(language));
    if (stored == null) return null;
    try {
      return PhoneVoice.fromMap(jsonDecode(stored));
    } catch (_) {
      return null;
    }
  }

  /// One of the phone's voices for [language] (none: its own); Echo's natural voice is
  /// no longer used.
  Future<void> choose(String language, PhoneVoice? voice) async {
    await _preferences.remove(naturalKey);
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
