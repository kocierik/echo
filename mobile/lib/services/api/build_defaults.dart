import 'package:flutter/foundation.dart';

/// The server compiled into the app: the one it signs in to.
///
/// Pass another with `flutter run --dart-define-from-file=dart_defines.json`
/// (see dart_defines.example.json). No key is ever compiled in: each phone gets
/// its own when it signs in.
abstract final class BuildDefaults {
  static const serverUrl = String.fromEnvironment(
    'ECHO_SERVER_URL',
    defaultValue: 'https://echo.man.ovh',
  );

  /// A test account a debug build signs in with by itself, to try the app without
  /// typing it (`flutter run --dart-define-from-file=dart_defines.dev.json`, see
  /// dart_defines.dev.example.json). Never in a release build: only debug reads it.
  static ({String email, String password})? devAccount() {
    if (!kDebugMode) return null;
    return devAccountFrom(
      const String.fromEnvironment('ECHO_DEV_EMAIL'),
      const String.fromEnvironment('ECHO_DEV_PASSWORD'),
    );
  }

  @visibleForTesting
  static ({String email, String password})? devAccountFrom(String email, String password) {
    final address = email.trim();
    if (address.isEmpty || password.isEmpty) return null;
    return (email: address, password: password);
  }
}
