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
}
