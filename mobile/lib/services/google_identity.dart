import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'api/build_defaults.dart';

/// Sign in with Google: the ID token Echo's server checks (POST /api/auth/google). On iOS
/// the app asks for it; in the browser Google's own button gives it ([webIdTokens]).
abstract final class GoogleIdentity {
  static String get _clientId =>
      kIsWeb ? BuildDefaults.googleWebClientId : BuildDefaults.googleIosClientId;

  /// Only where a client ID is built in, and only on iOS and the web (Android would also
  /// need the signing key's fingerprint registered with Google).
  static bool get available =>
      _clientId.isNotEmpty && (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void>? _ready;
  static Future<void> _initialize() =>
      _ready ??= GoogleSignIn.instance.initialize(clientId: _clientId);

  /// Asks the person to choose their Google account (iOS). Null when they cancel.
  static Future<String?> idToken() async {
    await _initialize();
    try {
      final account = await GoogleSignIn.instance.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// The tokens Google's button gives in the browser, one per sign-in.
  static Stream<String> webIdTokens() async* {
    await _initialize();
    await for (final event in GoogleSignIn.instance.authenticationEvents) {
      if (event case GoogleSignInAuthenticationEventSignIn(:final user)) {
        final token = user.authentication.idToken;
        if (token != null) yield token;
      }
    }
  }
}
