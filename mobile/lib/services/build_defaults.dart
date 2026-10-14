/// Backend values compiled into the app, used to prefill the onboarding.
///
/// Pass them with `flutter run --dart-define-from-file=dart_defines.json`
/// (see dart_defines.example.json). The API key has no default, so it is
/// never committed: without it the onboarding asks for it.
abstract final class BuildDefaults {
  static const serverUrl = String.fromEnvironment(
    'ECHO_SERVER_URL',
    defaultValue: 'https://echo.man.ovh',
  );

  static const apiKey = String.fromEnvironment('ECHO_API_KEY');
}
