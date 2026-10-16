import 'dart:convert';
import 'dart:io';

import '../../models/signed_in_device.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'build_defaults.dart';
import '../device/phone_name.dart';

/// Why signing in failed.
enum SignInFailure {
  wrongCredentials,
  tooManyAttempts,
  noConnection,
  server,

  /// Creating an account: the email has one already.
  accountExists,

  /// Creating an account: the server does not take new ones.
  registrationClosed,

  /// Creating an account: a bad email or a short password (the message says which).
  invalid,
}

final class SignInException implements Exception {
  const SignInException(this.reason, this.message);

  final SignInFailure reason;

  /// What to show the user.
  final String message;

  @override
  String toString() => 'SignInException($reason): $message';
}

/// The phones signed in to the account (Settings → Devices).
abstract interface class DevicesApi {
  Future<List<SignedInDevice>> listDevices();
  Future<void> revokeDevice(String id);
  Future<void> signOutThisPhone();
}

/// Signing in gives this phone its own key; signing out and revoking take keys away.
mixin AuthEndpoints on ApiClient implements DevicesApi {
  /// Signs in and keeps the key this phone was given, for the server set in Settings
  /// (development) or the one built into the app.
  ///
  /// [deviceName] names the phone in Devices; by default its model.
  Future<void> signIn({
    required String email,
    required String password,
    String? deviceName,
  }) =>
      _signInPhone('/api/auth/login', email, password, deviceName);

  /// Creates an account and keeps the key this phone was given in it.
  Future<void> register({
    required String email,
    required String password,
    String? deviceName,
  }) =>
      _signInPhone('/api/auth/register', email, password, deviceName);

  Future<void> _signInPhone(
    String path,
    String email,
    String password,
    String? deviceName,
  ) async {
    // Signing in again (back from the next step): the key it replaces goes first, so
    // no ghost phone stays in Devices
    if (await credentials.configured) {
      try {
        await signOutThisPhone();
      } catch (_) {}
    }
    final stored = await credentials.serverUrl;
    final server = stored.isEmpty ? BuildDefaults.serverUrl : stored;
    final name = deviceName ?? await phoneName();
    final ApiResponse response;
    try {
      // These are answers here, not a revoked key
      response = await send(
        () => httpClient.post(
          Uri.parse('$server$path'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': email.trim(),
            'password': password,
            'device_name': name,
            'platform': Platform.isIOS ? 'ios' : 'android',
          }),
        ),
        expect: const {200, 400, 401, 403, 409, 429},
        shape: JsonShape.map,
      );
    } on ApiException catch (error) {
      throw error.code == 'offline' || error.code == 'timeout'
          ? const SignInException(
              SignInFailure.noConnection,
              'No connection. Check your internet and try again.',
            )
          : const SignInException(
              SignInFailure.server,
              'Echo could not sign you in. Try again.',
            );
    }
    final data = response.data as Map<String, dynamic>;
    final detail = data['detail'];
    String said(String fallback) => detail is String && detail.isNotEmpty ? detail : fallback;
    switch (response.statusCode) {
      case 401:
        throw const SignInException(SignInFailure.wrongCredentials, 'Wrong email or password.');
      case 429:
        throw SignInException(
          SignInFailure.tooManyAttempts,
          said('Too many attempts. Try again later.'),
        );
      case 409:
        throw SignInException(
          SignInFailure.accountExists,
          said('An account with this email already exists. Sign in instead.'),
        );
      case 403:
        throw SignInException(
          SignInFailure.registrationClosed,
          said('Registration is closed.'),
        );
      case 400:
        throw SignInException(SignInFailure.invalid, said('Check your email and password.'));
    }
    final key = data['api_key'];
    if (key is! String || key.isEmpty) {
      throw const SignInException(SignInFailure.server, 'Echo could not sign you in. Try again.');
    }
    await credentials.configure(server, key);
  }

  /// Deletes this phone's key on the server; an already revoked key counts as done.
  @override
  Future<void> signOutThisPhone() async {
    // Short: logging out must not hang on an unreachable server
    await post(
      '/api/auth/logout',
      expect: const {204, 401},
      decode: false,
      timeout: const Duration(seconds: 3),
    );
  }

  /// The phones signed in to this account, this one marked.
  @override
  Future<List<SignedInDevice>> listDevices() async {
    final response = await get('/api/auth/devices', shape: JsonShape.list);
    return parse(response.data, (data) {
      return [
        for (final item in data as List<dynamic>)
          SignedInDevice.fromJson(item as Map<String, dynamic>),
      ];
    });
  }

  @override
  Future<void> revokeDevice(String id) => delete('/api/auth/devices/$id');
}
