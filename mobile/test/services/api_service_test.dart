import 'dart:async';
import 'dart:convert';

import 'package:echo_app/models/segment.dart';
import 'package:echo_app/services/api_exception.dart';
import 'package:echo_app/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('ApiService success statuses', () {
    test('decodes a 200 response', () async {
      final service = _service((request) => _jsonResponse(request, 200, {
            'answer': 'Found it',
            'session_id': 'session-1',
            'sources': <Object?>[],
            'date_filter': null,
          }));

      final response = await service.query('Where was I?');

      expect(response.answer, 'Found it');
      expect(response.sessionId, 'session-1');
    });

    test('decodes a 201 response', () async {
      final service = _service((request) => _jsonResponse(request, 201, {
            'id': 'rule-1',
            'name': 'Notify me',
          }));

      final rule = await service.createRule({
        'name': 'Notify me',
        'conditions': {'entity_type': 'task'},
        'actions': [
          {'type': 'tag'}
        ],
      });

      expect(rule?['id'], 'rule-1');
    });

    test('accepts a 204 response without decoding JSON', () async {
      final service = _service(
        (request) => _response(request, 204),
      );

      await expectLater(service.deleteRule('rule-1'), completes);
    });

    test('loads strict chat session detail from the detail endpoint', () async {
      late http.BaseRequest captured;
      final service = _service((request) {
        captured = request;
        return _jsonResponse(request, 200, {
          'id': 'session-1',
          'title': 'Planning',
          'messages': [
            {
              'role': 'user',
              'content': 'What did we decide?',
              'timestamp': null,
            },
          ],
          'created_at': '2026-10-01T09:30:00Z',
          'updated_at': '2026-10-01T09:31:00Z',
        });
      });

      final detail = await service.getSessionDetail('session-1');

      expect(
        captured.url.toString(),
        'https://echo.test/api/chat-sessions/session-1',
      );
      expect(detail.messages.single.content, 'What did we decide?');
    });

    test('deletes chat sessions only on 204', () async {
      final service = _service((request) => _response(request, 204));

      await expectLater(service.deleteSession('session-1'), completes);

      final wrongStatusService = _service(
        (request) => _jsonResponse(request, 200, {'deleted': true}),
      );
      await _expectApiException(
        wrongStatusService.deleteSession('session-1'),
        statusCode: 200,
        code: 'http',
      );
    });

    test('rejects 202 when it is not the endpoint expected status', () async {
      final service = _service(
        (request) => _jsonResponse(request, 202, <Object?>[]),
      );

      await _expectApiException(
        service.getRules(),
        statusCode: 202,
        code: 'http',
      );
    });

    for (final status in [200, 202]) {
      test('corrects a transcription on $status with the full payload',
          () async {
        late http.Request captured;
        final service = _service((request) {
          captured = request as http.Request;
          return _jsonResponse(request, status, {
            'segment_id': 'segment-1',
            'transcription_id': 'transcription-1',
            'text': 'Corrected memory',
            'speaker_label': 'other',
            'updated_at': '2026-10-02T12:00:00Z',
            'reanalysis_status': status == 202 ? 'queued' : 'unchanged',
          });
        });

        final result = await service.correctTranscription(
          'segment-1',
          '  Corrected memory  ',
          'other',
        );

        expect(
          captured.url.toString(),
          'https://echo.test/api/segments/segment-1/transcription',
        );
        expect(captured.method, 'PATCH');
        expect(captured.headers['content-type'], 'application/json');
        expect(captured.headers['X-API-Key'], 'test-key');
        expect(jsonDecode(captured.body), {
          'text': 'Corrected memory',
          'speaker': 'other',
        });
        expect(result, isA<TranscriptionCorrectionResult>());
        expect(result.text, 'Corrected memory');
        expect(result.speakerLabel, 'other');
      });
    }
  });

  group('ApiService HTTP errors', () {
    final cases = <({int status, String code, bool retryable})>[
      (status: 401, code: 'unauthorized', retryable: false),
      (status: 404, code: 'not_found', retryable: false),
      (status: 409, code: 'conflict', retryable: false),
      (status: 422, code: 'validation', retryable: false),
      (status: 500, code: 'server', retryable: true),
    ];

    for (final testCase in cases) {
      test('maps ${testCase.status} to ${testCase.code}', () async {
        final service = _service(
          (request) => _jsonResponse(
            request,
            testCase.status,
            {'detail': 'Backend detail'},
          ),
        );

        final error = await _expectApiException(
          service.query('question'),
          statusCode: testCase.status,
          code: testCase.code,
        );
        expect(error.message, 'Backend detail');
        expect(error.retryable, testCase.retryable);
      });
    }

    test('former silent list methods throw on server failures', () async {
      final operations = <Future<Object?> Function(ApiService)>[
        (service) => service.getSessions(),
        (service) => service.getConversations(),
        (service) => service.getTasks(),
        (service) => service.getAvailableProviders(),
        (service) => service.getUserIntegrations(),
        (service) => service.getRules(),
        (service) => service.getRuleTemplates(),
      ];

      for (final operation in operations) {
        final service = _service(
          (request) => _jsonResponse(request, 500, {'detail': 'Unavailable'}),
        );
        await _expectApiException(
          operation(service),
          statusCode: 500,
          code: 'server',
        );
      }
    });
  });

  group('ApiService response validation', () {
    test('maps malformed JSON to invalid_response', () async {
      final service = _service(
        (request) => _response(request, 200, body: '{not-json'),
      );

      await _expectApiException(
        service.getRules(),
        code: 'invalid_response',
      );
    });

    test('maps the wrong top-level JSON shape to invalid_response', () async {
      final service = _service(
        (request) => _jsonResponse(request, 200, {'rules': <Object?>[]}),
      );

      await _expectApiException(
        service.getRules(),
        code: 'invalid_response',
      );
    });

    test('maps malformed nested model fields to invalid_response', () async {
      final service = _service(
        (request) => _jsonResponse(request, 200, [
          {
            'id': 42,
            'received_at': 'not-a-date',
            'recorded_at': '2026-10-02T12:00:00Z',
            'duration_ms': '100',
            'transcription_status': 'completed',
          }
        ]),
      );

      await _expectApiException(
        service.getRecentSegments(),
        code: 'invalid_response',
      );
    });

    test('maps malformed chat detail fields to invalid_response', () async {
      final service = _service((request) => _jsonResponse(request, 200, {
            'id': 'session-1',
            'title': 'Planning',
            'messages': [
              {
                'role': 'system',
                'content': 'Hidden prompt',
                'timestamp': null,
              },
            ],
            'created_at': '2026-10-01T09:30:00Z',
            'updated_at': '2026-10-01T09:31:00Z',
          }));

      await _expectApiException(
        service.getSessionDetail('session-1'),
        code: 'invalid_response',
      );
    });

    test('maps a malformed correction result to invalid_response', () async {
      final service = _service((request) => _jsonResponse(request, 202, {
            'segment_id': 'segment-1',
            'transcription_id': 42,
            'text': 'Corrected memory',
            'speaker_label': 'self',
            'updated_at': '2026-10-02T12:00:00Z',
            'reanalysis_status': 'queued',
          }));

      await _expectApiException(
        service.correctTranscription(
          'segment-1',
          'Corrected memory',
          'self',
        ),
        code: 'invalid_response',
      );
    });
  });

  group('ApiService transport failures', () {
    test('maps request timeout to a retryable timeout error', () async {
      final service = _service(
        (request) => Completer<http.StreamedResponse>().future,
        requestTimeout: const Duration(milliseconds: 1),
      );

      final error = await _expectApiException(
        service.getRules(),
        code: 'timeout',
      );
      expect(error.retryable, isTrue);
    });

    test('maps ClientException to a retryable offline error', () async {
      final service = _service((request) {
        throw http.ClientException('No route to host', request.url);
      });

      final error = await _expectApiException(
        service.getRules(),
        code: 'offline',
      );
      expect(error.retryable, isTrue);
    });

    test('does not close an injected client when disposed', () {
      final client = _StubClient(
        (request) => _jsonResponse(request, 200, <Object?>[]),
      );
      final service = ApiService(
        client: client,
        credentialStore: _FakeCredentialStore(),
      );

      service.dispose();

      expect(client.closed, isFalse);
    });
  });

  group('credential probes', () {
    test('returns true only for 200 and sends the supplied key', () async {
      late http.BaseRequest captured;
      final service = _service((request) {
        captured = request;
        return _jsonResponse(request, 200, {'conversations': <Object?>[]});
      });

      expect(
        await service.validateCredentials('https://new.test/', ' new-key '),
        isTrue,
      );
      expect(captured.url.toString(),
          'https://new.test/api/conversations?limit=1');
      expect(captured.headers['X-API-Key'], 'new-key');
    });

    test('returns false for 401 and 403', () async {
      for (final status in [401, 403]) {
        final service = _service(
          (request) => _jsonResponse(request, status, {'detail': 'Denied'}),
        );
        expect(
          await service.validateCredentials('https://new.test', 'key'),
          isFalse,
        );
      }
    });

    test('propagates server failures', () async {
      final service = _service(
        (request) => _jsonResponse(request, 500, {'detail': 'Unavailable'}),
      );

      await _expectApiException(
        service.testConnection(),
        statusCode: 500,
        code: 'server',
      );
    });
  });

  group('multipart upload', () {
    test('uses the injected client and returns true on 201', () async {
      late http.BaseRequest captured;
      final service = _service((request) {
        captured = request;
        return _jsonResponse(request, 201, {'id': 'segment-1'});
      });

      final uploaded = await service.uploadSegment(
        audioData: [1, 2, 3],
        recordedAt: '2026-10-02T12:00:00Z',
        durationMs: 100,
      );

      expect(uploaded, isTrue);
      expect(captured, isA<http.MultipartRequest>());
      expect(captured.headers['X-API-Key'], 'test-key');
    });

    test('throws ApiException for a non-201 response', () async {
      final service = _service(
        (request) => _jsonResponse(request, 500, {'detail': 'Upload failed'}),
      );

      await _expectApiException(
        service.uploadSegment(
          audioData: [1],
          recordedAt: '2026-10-02T12:00:00Z',
          durationMs: 100,
        ),
        statusCode: 500,
        code: 'server',
      );
    });
  });

  test('clearConfiguration delegates to the credential store', () async {
    final store = _FakeCredentialStore();
    final service = ApiService(
      client: _StubClient(
        (request) => _jsonResponse(request, 200, <Object?>[]),
      ),
      credentialStore: store,
    );

    await service.clearConfiguration();

    expect(store.clearCalls, 1);
  });
}

ApiService _service(
  Future<http.StreamedResponse> Function(http.BaseRequest) handler, {
  Duration requestTimeout = const Duration(seconds: 10),
  Duration uploadTimeout = const Duration(seconds: 20),
}) {
  return ApiService(
    client: _StubClient(handler),
    credentialStore: _FakeCredentialStore(),
    requestTimeout: requestTimeout,
    uploadTimeout: uploadTimeout,
  );
}

Future<ApiException> _expectApiException(
  Future<Object?> operation, {
  int? statusCode,
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

Future<http.StreamedResponse> _jsonResponse(
  http.BaseRequest request,
  int statusCode,
  Object? body,
) {
  return _response(request, statusCode, body: jsonEncode(body));
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
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);

  @override
  void close() {
    closed = true;
  }
}

final class _FakeCredentialStore implements ApiCredentialStore {
  int clearCalls = 0;

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
  Future<void> clear() async {
    clearCalls++;
  }

  @override
  Future<void> configure(String serverUrl, String apiKey) async {}
}