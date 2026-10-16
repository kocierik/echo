import 'dart:convert';
import 'dart:io';

import '../../models/signed_in_device.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'build_defaults.dart';
import '../device/phone_name.dart';

/// Why signing in failed.
enum SignInFailure { wrongCredentials, tooManyAttempts, noConnection, server }

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
  }) async {
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
      // 401 and 429 are answers here, not a revoked key
      response = await send(
        () => httpClient.post(
          Uri.parse('$server/api/auth/login'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': email.trim(),
            'password': password,
            'device_name': name,
            'platform': Platform.isIOS ? 'ios' : 'android',
          }),
        ),
        expect: const {200, 401, 429},
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
    switch (response.statusCode) {
      case 401:
        throw const SignInException(SignInFailure.wrongCredentials, 'Wrong email or password.');
      case 429:
        throw SignInException(
          SignInFailure.tooManyAttempts,
          data['detail'] as String? ?? 'Too many attempts. Try again later.',
        );
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
