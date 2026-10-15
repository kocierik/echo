import 'dart:convert';

import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('deletes a conversation only when the API returns 204', () async {
    late http.BaseRequest captured;
    final service = _service((request) {
      captured = request;
      return _response(request, 204);
    });

    await expectLater(service.deleteConversation('conversation-1'), completes);

    expect(captured.method, 'DELETE');
    expect(
      captured.url.toString(),
      'https://echo.test/api/conversations/conversation-1',
    );
    expect(captured.headers['X-API-Key'], 'test-key');
  });

  for (final testCase in [
    (status: 404, code: 'not_found', retryable: false),
    (status: 500, code: 'server', retryable: true),
  ]) {
    test('maps ${testCase.status} to a typed ${testCase.code} error', () async {
      final service = _service(
        (request) => _response(
          request,
          testCase.status,
          body: jsonEncode({'detail': 'Delete failed'}),
        ),
      );

      final error = await _expectApiException(
        service.deleteConversation('conversation-1'),
        statusCode: testCase.status,
        code: testCase.code,
      );
      expect(error.message, 'Delete failed');
      expect(error.retryable, testCase.retryable);
    });
  }

  test('rejects a 200 response for conversation deletion', () async {
    final service = _service(
      (request) => _response(
        request,
        200,
        body: jsonEncode({'deleted': true}),
      ),
    );

    await _expectApiException(
      service.deleteConversation('conversation-1'),
      statusCode: 200,
      code: 'http',
    );
  });
}

ApiService _service(
  Future<http.StreamedResponse> Function(http.BaseRequest) handler,
) {
  return ApiService(
    client: _StubClient(handler),
    credentialStore: _FakeCredentialStore(),
  );
}

Future<ApiException> _expectApiException(
  Future<Object?> operation, {
  required int statusCode,
  required String code,
}) async {
  try {
    await operation;
    fail('Expected ApiException');
  } on ApiException catch (error) {
    expect(error.statusCode, statusCode);
    expect(error.code, code);
    return error;
  }
}

Future<http.StreamedResponse> _response(
  http.BaseRequest request,
  int statusCode, {
  String body = '',
}) async {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    statusCode,
    request: request,
    headers: const {'content-type': 'application/json'},
  );
}

final class _StubClient extends http.BaseClient {
  _StubClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}

final class _FakeCredentialStore implements ApiCredentialStore {
  @override
  Future<bool> get configured async => true;

  @override
  Future<Map<String, String>> get headers async => const {
        'X-API-Key': 'test-key',
        'Content-Type': 'application/json',
      };

  @override
  Future<String> get serverUrl async => 'https://echo.test';

  @override
  Future<void> clear() async {}

  @override
  Future<void> configure(String serverUrl, String apiKey) async {}
}