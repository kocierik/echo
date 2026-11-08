import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_credentials.dart';
import 'api_exception.dart';
import 'response_cache.dart';

/// What a JSON body must be; anything else is an `invalid_response`.
enum JsonShape { any, map, list }

final class ApiResponse {
  const ApiResponse(this.statusCode, this.data);

  final int statusCode;
  final Object? data;
}

/// The HTTP side every group of endpoints shares: the server and its key, timeouts,
/// the phone's copy of reads, and failures mapped to [ApiException].
///
/// The endpoints are mixins on this class (chat_api.dart, memory_api.dart, …),
/// put together by `ApiService`.
abstract class ApiClient {
  ApiClient({
    http.Client? client,
    ApiCredentialStore? credentialStore,
    this.requestTimeout = const Duration(seconds: 10),
    this.uploadTimeout = const Duration(seconds: 20),
    this.queryTimeout = const Duration(seconds: 90),
    ResponseCache? cache,
    this.cacheOnly = false,
  })  : httpClient = client ?? http.Client(),
        cache = cache ?? FileResponseCache.shared,
        credentials = credentialStore ?? SharedPreferencesApiCredentialStore(),
        _ownsClient = client == null;

  /// Every 401 a request did not expect, from any instance: the stored key no longer
  /// opens the server (revoked from another phone), so the session signs out.
  static Stream<void> get unauthorized => _unauthorized.stream;
  static final _unauthorized = StreamController<void>.broadcast();

  /// A 401 for the key the request carried: reported only while that key is still
  /// the stored one (a request sent before signing in again says nothing).
  @protected
  Future<void> reportUnauthorized(String? sentKey) async {
    // Sent without a key: the phone could not read it (the Keychain with the screen
    // locked), which says nothing about the key the server holds
    if (sentKey == null || sentKey.isEmpty) return;
    final current = (await credentials.headers)['X-API-Key'];
    if (sentKey == current) _unauthorized.add(null);
  }

  @protected
  final http.Client httpClient;
  @protected
  final ApiCredentialStore credentials;
  @protected
  final Duration requestTimeout;
  @protected
  final Duration uploadTimeout;

  /// Chat queries may run several tool calls on connected apps.
  @protected
  final Duration queryTimeout;
  @protected
  final ResponseCache cache;

  /// Reads only the phone's copy: for showing a screen before the server answers.
  @protected
  final bool cacheOnly;
  final bool _ownsClient;

  void dispose() {
    if (_ownsClient) httpClient.close();
  }

  /// `path` (with its query, if any) on the configured server.
  @protected
  Future<Uri> url(String path) async =>
      Uri.parse('${await credentials.serverUrl}$path');

  @protected
  Future<ApiResponse> get(
    String path, {
    Set<int> expect = const {200},
    JsonShape shape = JsonShape.map,
  }) async {
    final target = await url(path);
    final headers = await credentials.headers;
    return send(
      () => httpClient.get(target, headers: headers),
      sentKey: headers['X-API-Key'],
      expect: expect,
      shape: shape,
    );
  }

  /// [body] is sent as JSON; without one the request has no body.
  @protected
  Future<ApiResponse> post(
    String path, {
    Object? body,
    Set<int> expect = const {200},
    JsonShape shape = JsonShape.map,
    bool decode = true,
    Duration? timeout,
  }) async {
    final target = await url(path);
    final headers = await credentials.headers;
    return send(
      () => httpClient.post(
        target,
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
      sentKey: headers['X-API-Key'],
      expect: expect,
      shape: shape,
      decode: decode,
      timeout: timeout,
    );
  }

  @protected
  Future<ApiResponse> patch(
    String path, {
    required Object body,
    Set<int> expect = const {200},
    JsonShape shape = JsonShape.map,
  }) async {
    final target = await url(path);
    final headers = await credentials.headers;
    return send(
      () => httpClient.patch(target, headers: headers, body: jsonEncode(body)),
      sentKey: headers['X-API-Key'],
      expect: expect,
      shape: shape,
    );
  }

  @protected
  Future<ApiResponse> put(
    String path, {
    required Object body,
    Set<int> expect = const {200},
    JsonShape shape = JsonShape.map,
    bool decode = true,
  }) async {
    final target = await url(path);
    final headers = await credentials.headers;
    return send(
      () => httpClient.put(target, headers: headers, body: jsonEncode(body)),
      sentKey: headers['X-API-Key'],
      expect: expect,
      shape: shape,
      decode: decode,
    );
  }

  @protected
  Future<void> delete(String path, {Set<int> expect = const {204}}) async {
    final target = await url(path);
    final headers = await credentials.headers;
    await send(
      () => httpClient.delete(target, headers: headers),
      sentKey: headers['X-API-Key'],
      expect: expect,
      decode: false,
    );
  }

  /// A read that keeps its answer on the phone, and falls back to it when the server
  /// cannot be reached (then [offlineDataSince] says since when the data is).
  @protected
  Future<ApiResponse> getCached(
    String path, {
    JsonShape shape = JsonShape.map,
  }) async {
    final key = '${await credentials.serverUrl}$path';
    if (cacheOnly) {
      final cached = await cache.read(key);
      if (cached == null) throw offlineException('no copy on this phone');
      return ApiResponse(200, decodeJson(cached.body, shape: shape));
    }
    final headers = await credentials.headers;
    try {
      final response = await send(
        () => httpClient.get(Uri.parse(key), headers: headers),
        sentKey: headers['X-API-Key'],
        expect: const {200},
        shape: shape,
      );
      unawaited(cache.write(key, jsonEncode(response.data)));
      offlineDataSince.value = null;
      return response;
    } on ApiException catch (error) {
      if (error.code != 'offline' && error.code != 'timeout') rethrow;
      final cached = await cache.read(key);
      if (cached == null) rethrow;
      offlineDataSince.value = cached.savedAt;
      return ApiResponse(200, decodeJson(cached.body, shape: shape));
    }
  }

  /// A download of raw bytes (an export, a firmware image), with the long timeout.
  @protected
  Future<Uint8List> getBytes(String path) async {
    final target = await url(path);
    final headers = await credentials.headers;
    final response = await guard(
      () => httpClient.get(target, headers: headers).timeout(queryTimeout),
    );
    if (response.statusCode != 200) {
      if (response.statusCode == 401) await reportUnauthorized(headers['X-API-Key']);
      throw statusException(response.statusCode, response.body);
    }
    return response.bodyBytes;
  }

  /// A multipart request carrying the API key; the caller adds headers and files.
  @protected
  Future<http.MultipartRequest> multipart(String method, String path) async {
    final headers = await credentials.headers;
    return http.MultipartRequest(method, await url(path))
      ..headers['X-API-Key'] = headers['X-API-Key'] ?? '';
  }

  /// Sends a multipart request within [uploadTimeout].
  @protected
  Future<({int statusCode, String body})> upload(http.MultipartRequest request) async {
    Future<({int statusCode, String body})> transfer() async {
      final streamed = await httpClient.send(request);
      return (
        statusCode: streamed.statusCode,
        body: await streamed.stream.bytesToString(),
      );
    }

    final result = await guard(() => transfer().timeout(uploadTimeout));
    if (result.statusCode == 401) await reportUnauthorized(request.headers['X-API-Key']);
    return result;
  }

  /// Runs [request] within [timeout] (default [requestTimeout]); a status outside
  /// [expect] is an [ApiException], and so is a body that is not JSON of [shape].
  @protected
  Future<ApiResponse> send(
    Future<http.Response> Function() request, {
    required Set<int> expect,
    String? sentKey,
    bool decode = true,
    JsonShape shape = JsonShape.any,
    Duration? timeout,
  }) async {
    final response =
        await guard(() => request().timeout(timeout ?? requestTimeout));
    if (!expect.contains(response.statusCode)) {
      if (response.statusCode == 401) {
        await reportUnauthorized(sentKey ?? response.request?.headers['X-API-Key']);
      }
      throw statusException(response.statusCode, response.body);
    }
    return ApiResponse(
      response.statusCode,
      decode ? decodeJson(response.body, shape: shape) : null,
    );
  }

  /// Timeouts and network failures as retryable [ApiException]s.
  @protected
  Future<T> guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on TimeoutException {
      throw timeoutException();
    } on http.ClientException catch (error) {
      throw offlineException(error);
    } on IOException catch (error) {
      throw offlineException(error);
    }
  }

  @protected
  Object? decodeJson(String body, {required JsonShape shape}) {
    late final Object? data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      throw invalidResponseException();
    }
    if (shape == JsonShape.map && data is! Map<String, dynamic>) {
      throw invalidResponseException();
    }
    if (shape == JsonShape.list && data is! List<dynamic>) {
      throw invalidResponseException();
    }
    return data;
  }

  /// [read] on decoded JSON; anything it throws (but an [ApiException]) means the
  /// server answered something else than expected.
  @protected
  T parse<T>(Object? data, T Function(Object? data) read) {
    try {
      return read(data);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw invalidResponseException();
    }
  }

  @protected
  ApiException statusException(int statusCode, String body) {
    final message =
        _extractDetail(body) ?? 'Request failed with HTTP $statusCode.';
    final (code, retryable) = switch (statusCode) {
      401 => ('unauthorized', false),
      403 => ('forbidden', false),
      404 => ('not_found', false),
      408 => ('timeout', true),
      409 => ('conflict', false),
      410 => ('expired', false),
      422 => ('validation', false),
      429 => ('rate_limited', true),
      503 => ('unavailable', true),
      >= 500 => ('server', true),
      _ => ('http', false),
    };
    return ApiException(
      statusCode: statusCode,
      code: code,
      message: message,
      retryable: retryable,
    );
  }

  @protected
  ApiException timeoutException() => const ApiException(
        statusCode: null,
        code: 'timeout',
        message: 'The request timed out.',
        retryable: true,
      );

  @protected
  ApiException offlineException(Object error) => ApiException(
        statusCode: null,
        code: 'offline',
        message: 'The server could not be reached: $error',
        retryable: true,
      );

  @protected
  ApiException invalidResponseException() => const ApiException(
        statusCode: null,
        code: 'invalid_response',
        message: 'The server returned an invalid response.',
        retryable: false,
      );

  String? _extractDetail(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        final detail = data['detail'];
        if (detail is String && detail.isNotEmpty) return detail;
      }
    } catch (_) {}
    return null;
  }
}
