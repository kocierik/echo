import 'dart:async';
import 'dart:convert';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/segment.dart';
import 'package:echo_app/models/today_insights.dart';
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
        service.getToolkits(),
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
      (status: 410, code: 'expired', retryable: false),
      (status: 503, code: 'unavailable', retryable: true),
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
        (service) => service.getToolkits(),
        (service) => service.getActionLog(),
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
        service.getToolkits(),
        code: 'invalid_response',
      );
    });

    test('maps the wrong top-level JSON shape to invalid_response', () async {
      final service = _service(
        (request) => _jsonResponse(request, 200, {'rules': <Object?>[]}),
      );

      await _expectApiException(
        service.getToolkits(),
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
        service.getToolkits(),
        code: 'timeout',
      );
      expect(error.retryable, isTrue);
    });

    test('maps ClientException to a retryable offline error', () async {
      final service = _service((request) {
        throw http.ClientException('No route to host', request.url);
      });

      final error = await _expectApiException(
        service.getToolkits(),
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

  group('Today insights', () {
    test('latest digest is the newest non-empty summary of the last two days',
        () async {
      late http.BaseRequest captured;
      final service = _service((request) {
        captured = request;
        return _jsonResponse(request, 200, {
          'items': [
            {'digest_date': '2026-10-12', 'summary': '  '},
            {'digest_date': '2026-10-11', 'summary': 'Met Ada about Atlas.'},
          ],
          'count': 2,
        });
      });

      final digest = await service.getLatestDigest();

      expect(captured.url.toString(), 'https://echo.test/api/digest?days=2');
      expect(digest?.summary, 'Met Ada about Atlas.');
      expect(digest?.date, DateTime(2026, 10, 11));
    });

    test('latest digest is null when no digest exists', () async {
      final service = _service((request) => _jsonResponse(request, 200, {
            'items': <Object?>[],
            'count': 0,
          }));

      expect(await service.getLatestDigest(), isNull);
    });

    test('open tasks skip done and nameless tasks and parse due dates',
        () async {
      final now = DateTime.now().toUtc().toIso8601String();
      final service = _service((request) => _jsonResponse(request, 200, {
            'entities': [
              {
                'id': 'open',
                'name': 'Call Ada',
                'metadata_': {'done': false, 'due_date': '2026-10-14'},
                'created_at': now,
              },
              {
                'id': 'done',
                'name': 'Send report',
                'metadata_': {'done': true},
                'created_at': now,
              },
              {'id': 'blank', 'name': ' ', 'metadata_': {}, 'created_at': now},
            ],
            'total': 3,
          }));

      final tasks = await service.getOpenTasks();

      expect(tasks.map((task) => task.id), ['open']);
      expect(tasks.single.dueDate, DateTime(2026, 10, 14));
    });

    test('completing a task sends the full metadata with done true', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {'id': 'task-1'});
      });

      await service.completeTask(const OpenTask(
        id: 'task-1',
        name: 'Call Ada',
        metadata: {'done': false, 'priority': 'high'},
      ));

      expect(captured.method, 'PATCH');
      expect(captured.url.toString(), 'https://echo.test/api/entities/task-1');
      expect(jsonDecode(captured.body), {
        'metadata_': {'done': true, 'priority': 'high'},
      });
    });
  });

  group('ApiService Composio actions', () {
    test('getToolkits sends the query and parses toolkits', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, [
          {
            'slug': 'gmail',
            'name': 'Gmail',
            'description': 'Email',
            'connected': true,
          },
        ]);
      });

      final toolkits = await service.getToolkits(query: 'mail');

      expect(captured.method, 'GET');
      expect(captured.url.path, '/api/actions/toolkits');
      expect(captured.url.queryParameters, {'query': 'mail'});
      expect(captured.headers['X-API-Key'], 'test-key');
      expect(toolkits.single.slug, 'gmail');
      expect(toolkits.single.connected, isTrue);
    });

    test('getToolkits omits an empty query', () async {
      late http.BaseRequest captured;
      final service = _service((request) {
        captured = request;
        return _jsonResponse(request, 200, <Object?>[]);
      });

      await service.getToolkits();

      expect(captured.url.toString(), 'https://echo.test/api/actions/toolkits');
    });

    test('getToolkits maps malformed items to invalid_response', () async {
      final service = _service(
        (request) => _jsonResponse(request, 200, [
          {'slug': 'gmail'},
        ]),
      );

      await _expectApiException(
        service.getToolkits(),
        code: 'invalid_response',
      );
    });

    test('connectToolkit posts and returns the url', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {'url': 'https://auth.test/x'});
      });

      final url = await service.connectToolkit('gmail');

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/actions/toolkits/gmail/connect');
      expect(url, 'https://auth.test/x');
    });

    test('disconnectToolkit deletes and accepts 204', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _response(request, 204);
      });

      await service.disconnectToolkit('gmail');

      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/api/actions/toolkits/gmail');
    });

    test('confirmPendingAction posts and returns the message', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(
          request,
          200,
          {'status': 'executed', 'message': 'Sent'},
        );
      });

      final result = await service.confirmPendingAction('p1');

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/actions/pending/p1/confirm');
      expect(result.status, 'executed');
      expect(result.message, 'Sent');
    });

    test('confirmPendingAction maps 409 and 410', () async {
      final conflict = _service(
        (request) => _jsonResponse(request, 409, {'detail': 'Already done'}),
      );
      final error = await _expectApiException(
        conflict.confirmPendingAction('p1'),
        statusCode: 409,
        code: 'conflict',
      );
      expect(error.message, 'Already done');

      final expired = _service(
        (request) => _jsonResponse(request, 410, {'detail': 'Expired'}),
      );
      await _expectApiException(
        expired.confirmPendingAction('p1'),
        statusCode: 410,
        code: 'expired',
      );
    });

    test('503 maps to unavailable with the server detail', () async {
      final service = _service(
        (request) => _jsonResponse(
          request,
          503,
          {'detail': 'Composio is not configured'},
        ),
      );

      final error = await _expectApiException(
        service.getToolkits(),
        statusCode: 503,
        code: 'unavailable',
      );
      expect(error.retryable, isTrue);
      expect(error.message, 'Composio is not configured');
    });

    test('cancelPendingAction posts to cancel', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {'status': 'cancelled'});
      });

      await service.cancelPendingAction('p1');

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/actions/pending/p1/cancel');
    });

    test('getActionLog requests the limit and parses entries', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, [
          {
            'tool': 'GMAIL_SEND_EMAIL',
            'toolkit': 'gmail',
            'arguments_summary': 'to: ada',
            'outcome': 'failed',
            'error': 'boom',
            'source': 'chat',
            'created_at': '2026-10-13T10:00:00Z',
          },
        ]);
      });

      final log = await service.getActionLog();

      expect(captured.url.path, '/api/actions/log');
      expect(captured.url.queryParameters, {'limit': '50'});
      expect(log.single.tool, 'GMAIL_SEND_EMAIL');
      expect(log.single.error, 'boom');
      expect(log.single.createdAt, DateTime.parse('2026-10-13T10:00:00Z'));
    });

    test('getVoiceUpdates sends since and parses messages', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {
          'messages': [
            {
              'session_id': 's1',
              'role': 'assistant',
              'content': 'Done',
              'timestamp': '2026-10-13T10:00:00Z',
              'pending_action': {
                'id': 'p1',
                'summary': 'Send email',
                'status': 'pending',
                'expires_at': '2026-10-13T10:10:00Z',
              },
            },
          ],
          'now': '2026-10-13T10:01:00Z',
        });
      });

      final updates = await service.getVoiceUpdates(
        DateTime.utc(2026, 10, 13, 9),
      );

      expect(captured.url.path, '/api/actions/voice-updates');
      expect(
        captured.url.queryParameters['since'],
        DateTime.utc(2026, 10, 13, 9).toIso8601String(),
      );
      expect(updates.now, DateTime.parse('2026-10-13T10:01:00Z'));
      expect(updates.messages.single.sessionId, 's1');
      expect(updates.messages.single.pendingAction?.id, 'p1');
      expect(updates.messages.single.pendingAction?.status, 'pending');
    });

    test('getVoiceUpdates omits since when null', () async {
      late http.BaseRequest captured;
      final service = _service((request) {
        captured = request;
        return _jsonResponse(request, 200, {
          'messages': <Object?>[],
          'now': '2026-10-13T10:01:00Z',
        });
      });

      await service.getVoiceUpdates(null);

      expect(captured.url.query, isEmpty);
    });

    test('query parses pending_action', () async {
      final service = _service((request) => _jsonResponse(request, 200, {
            'answer': 'Confirm?',
            'session_id': 's1',
            'sources': <Object?>[],
            'pending_action': {
              'id': 'p1',
              'summary': 'Send email',
              'status': 'pending',
              'expires_at': '2026-10-13T10:10:00Z',
            },
          }));

      final response = await service.query('send it');

      final PendingAction? pending = response.pendingAction;
      expect(pending?.id, 'p1');
      expect(pending?.summary, 'Send email');
      expect(pending?.expiresAt, DateTime.parse('2026-10-13T10:10:00Z'));
    });

    test('query without pending_action leaves it null', () async {
      final service = _service((request) => _jsonResponse(request, 200, {
            'answer': 'Hi',
            'session_id': 's1',
            'sources': <Object?>[],
            'pending_action': null,
          }));

      final response = await service.query('hello');

      expect(response.pendingAction, isNull);
    });

    test('session detail parses pending_action without expires_at', () async {
      final service = _service((request) => _jsonResponse(request, 200, {
            'id': 'session-1',
            'title': null,
            'messages': [
              {
                'role': 'assistant',
                'content': 'Confirm?',
                'timestamp': null,
                'actions': true,
                'pending_action': {
                  'id': 'p1',
                  'summary': 'Send email',
                  'status': 'pending',
                },
              },
            ],
            'created_at': '2026-10-13T09:30:00Z',
            'updated_at': '2026-10-13T09:31:00Z',
          }));

      final detail = await service.getSessionDetail('session-1');

      final pending = detail.messages.single.pendingAction;
      expect(pending?.id, 'p1');
      expect(pending?.expiresAt, isNull);
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