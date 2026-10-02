import 'package:shared_preferences/shared_preferences.dart';

abstract interface class AppPreferences {
  String? getString(String key);
  int? getInt(String key);
  bool? getBool(String key);
  Future<bool> setString(String key, String value);
  Future<bool> setInt(String key, int value);
  Future<bool> setBool(String key, bool value);
}

final class SharedPreferencesAppPreferences implements AppPreferences {
  const SharedPreferencesAppPreferences(this._preferences);

  final SharedPreferences _preferences;

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  int? getInt(String key) => _preferences.getInt(key);

  @override
  bool? getBool(String key) => _preferences.getBool(key);

  @override
  Future<bool> setString(String key, String value) {
    return _preferences.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) {
    return _preferences.setInt(key, value);
  }

  @override
  Future<bool> setBool(String key, bool value) {
    return _preferences.setBool(key, value);
  }
}