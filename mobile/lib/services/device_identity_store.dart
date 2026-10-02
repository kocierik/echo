import 'package:shared_preferences/shared_preferences.dart';

abstract interface class DeviceIdentityStorePort {
  Future<String?> loadRemoteId();
  Future<void> saveRemoteId(String remoteId);
  Future<void> clear();
}

final class DeviceIdentityStore implements DeviceIdentityStorePort {
  DeviceIdentityStore(this._preferences);

  static const String remoteIdKey = 'echo_device_remote_id';

  final SharedPreferences _preferences;

  @override
  Future<String?> loadRemoteId() async =>
      _preferences.getString(remoteIdKey);

  @override
  Future<void> saveRemoteId(String remoteId) async {
    await _preferences.setString(remoteIdKey, remoteId);
  }

  @override
  Future<void> clear() async {
    await _preferences.remove(remoteIdKey);
  }
}