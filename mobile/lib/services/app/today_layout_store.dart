import 'package:shared_preferences/shared_preferences.dart';

import '../../models/today_layout.dart';

/// Today's layout on this phone (never on the server).
final class TodayLayoutStore {
  TodayLayoutStore({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  static const key = 'today_layout';

  final Future<SharedPreferences> Function() _preferences;

  Future<TodayLayout> load() async {
    try {
      return TodayLayout.fromJson((await _preferences()).getString(key));
    } catch (_) {
      return TodayLayout.defaults;
    }
  }

  Future<void> save(TodayLayout layout) async {
    await (await _preferences()).setString(key, layout.toJson());
  }
}
