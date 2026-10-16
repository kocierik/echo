import 'dart:convert';
import 'dart:io';

import '../../models/signed_in_device.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'build_defaults.dart';

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

/// Signing in gives this phone its own key; signing out and revoking take keys away.
mixin AuthEndpoints on ApiClient {
  /// Signs in and keeps the key this phone was given, for the server set in Settings
  /// (development) or the one built into the app.
  Future<void> signIn({required String email, required String password}) async {
    final stored = await credentials.serverUrl;
    final server = stored.isEmpty ? BuildDefaults.serverUrl : stored;
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
            'device_name': Platform.isIOS ? 'iPhone' : 'Android phone',
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
  Future<void> signOutThisPhone() async {
    await post('/api/auth/logout', expect: const {204, 401}, decode: false);
  }

  /// The phones signed in to this account, this one marked.
  Future<List<SignedInDevice>> listDevices() async {
    final response = await get('/api/auth/devices', shape: JsonShape.list);
    return parse(response.data, (data) {
      return [
        for (final item in data as List<dynamic>)
          SignedInDevice.fromJson(item as Map<String, dynamic>),
      ];
    });
  }

  Future<void> revokeDevice(String id) => delete('/api/auth/devices/$id');
}
