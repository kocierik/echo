import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the server URL and the API key live: the key in the Keychain (in the
/// preferences only when the Keychain fails), the URL in the preferences.
abstract interface class ApiCredentialStore {
  Future<bool> get configured;
  Future<String> get serverUrl;
  Future<Map<String, String>> get headers;
  Future<void> configure(String serverUrl, String apiKey);
  Future<void> clear();
}

final class SharedPreferencesApiCredentialStore implements ApiCredentialStore {
  SharedPreferencesApiCredentialStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<SharedPreferences> Function()? preferences,
  })  : _secureStorage = secureStorage,
        _preferences = preferences ?? SharedPreferences.getInstance;

  static const serverKey = 'echo_server_url';
  static const apiKeyKey = 'echo_api_key';

  /// Readable with the screen locked, once the phone was unlocked after starting: the
  /// wearable's speech is uploaded from the background. The default (only while
  /// unlocked) sent the key empty from a locked phone, and its 401 signed the phone out.
  static const _keychain =
      IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<bool> get configured async {
    final preferences = await _preferences();
    final server = preferences.getString(serverKey);
    final key = await _readApiKey(preferences);
    return server != null &&
        server.isNotEmpty &&
        key != null &&
        key.isNotEmpty;
  }

  @override
  Future<String> get serverUrl async {
    final preferences = await _preferences();
    return preferences.getString(serverKey) ?? '';
  }

  @override
  Future<Map<String, String>> get headers async {
    final preferences = await _preferences();
    final key = await _readApiKey(preferences);
    return {
      'X-API-Key': key ?? '',
      'Content-Type': 'application/json',
    };
  }

  @override
  Future<void> configure(String serverUrl, String apiKey) async {
    final preferences = await _preferences();
    final normalizedServer =
        serverUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final normalizedKey = apiKey.trim();
    await preferences.setString(serverKey, normalizedServer);
    try {
      await _secureStorage.write(key: apiKeyKey, value: normalizedKey, iOptions: _keychain);
    } catch (_) {
      await preferences.setString(apiKeyKey, normalizedKey);
      return;
    }
    await preferences.remove(apiKeyKey);
  }

  @override
  Future<void> clear() async {
    Object? firstError;
    try {
      await _secureStorage.delete(key: apiKeyKey);
    } catch (error) {
      firstError = error;
    }

    try {
      final preferences = await _preferences();
      try {
        await preferences.remove(apiKeyKey);
      } catch (error) {
        firstError ??= error;
      }
      try {
        await preferences.remove(serverKey);
      } catch (error) {
        firstError ??= error;
      }
    } catch (error) {
      firstError ??= error;
    }

    if (firstError != null) {
      throw StateError('Failed to clear API credentials: $firstError');
    }
  }

  Future<String?> _readApiKey(SharedPreferences preferences) async {
    try {
      final key = await _secureStorage.read(key: apiKeyKey, iOptions: _keychain);
      if (key != null && key.isNotEmpty) return key;
      // Saved before with the default accessibility, which reads only while unlocked
      // (the query filters on it): moved over once, so no phone is signed out by the update
      final earlier = await _secureStorage.read(key: apiKeyKey);
      if (earlier != null && earlier.isNotEmpty) {
        await _secureStorage.delete(key: apiKeyKey);
        try {
          await _secureStorage.write(key: apiKeyKey, value: earlier, iOptions: _keychain);
        } catch (_) {
          await preferences.setString(apiKeyKey, earlier); // never lost on the way
        }
        return earlier;
      }
    } catch (_) {}
    return preferences.getString(apiKeyKey);
  }
}
