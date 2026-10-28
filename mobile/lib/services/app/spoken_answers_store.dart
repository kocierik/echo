import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// When the phone reads Echo's answers aloud: never, only in headphones, or also on the
/// speaker.
enum SpokenAnswers { off, headphones, always }

/// Profile → Spoken answers, kept on this phone; off until chosen.
final class SpokenAnswersStore extends ValueNotifier<SpokenAnswers> {
  SpokenAnswersStore(this._preferences) : super(_read(_preferences));

  static const key = 'spoken_answers';

  final SharedPreferences _preferences;

  static SpokenAnswers _read(SharedPreferences preferences) {
    final stored = preferences.getString(key);
    return SpokenAnswers.values.firstWhere(
      (choice) => choice.name == stored,
      orElse: () => SpokenAnswers.off,
    );
  }

  Future<void> set(SpokenAnswers choice) async {
    value = choice;
    await _preferences.setString(key, choice.name);
  }
}
