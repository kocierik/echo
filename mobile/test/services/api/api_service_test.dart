import 'dart:async';
import 'dart:convert';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/device_command.dart';
import 'package:echo_app/models/saved.dart';
import 'package:echo_app/models/segment.dart';
import 'package:echo_app/models/task_item.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/api/response_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('Saved', () {
    Map<String, dynamic> item(String id) => {
          'id': id,
          'list_id': 'l1',
          'list': 'Wines',
          'title': 'Barolo',
          'fields': <String, dynamic>{},
          'people': <Object?>[],
          'saved_at': '2026-10-18T19:40:00Z',
        };

    test('reads the page, searches and moves, removes and places', () async {
      final calls = <String>[];
      final bodies = <String>[];
      final service = _service((request) async {
        calls.add('${request.method} ${request.url.path}?${request.url.query}');
        if (request is http.Request) bodies.add(request.body);
        if (request.method == 'DELETE') return _response(request, 204);
        if (request.url.query.startsWith('q=')) {
          return _jsonResponse(request, 200, {
            'results': [item('i1')],
          });
        }
        if (request.url.path == '/api/saved') {
          return _jsonResponse(request, 200, {
            'total': 1,
            'latest_list': 'Wines',
            'places': <Object?>[],
            'lists': <Object?>[],
          });
        }
        if (request.url.path == '/api/saved/lists') {
          return _jsonResponse(request, 200, [
            {'id': 'l1', 'name': 'Wines', 'count': 1},
          ]);
        }
        return _jsonResponse(request, 200, item('i1'));
      });

      expect((await service.getSaved()).latestList, 'Wines');
      expect((await service.searchSaved('vino rosso')).single.id, 'i1');
      expect((await service.listSavedLists()).single.name, 'Wines');
      expect((await service.moveSavedItem('i1', 'Books')).id, 'i1');
      await service.deleteSavedItem('i1');
      await service.putSavedPlace(
        'i1',
        const SavedPlace(latitude: 45.4, longitude: 9.1, address: 'Via Roma 12'),
      );

      expect(calls, [
        'GET /api/saved?',
        'GET /api/saved?q=vino+rosso',
        'GET /api/saved/lists?',
        'PATCH /api/saved/items/i1?',
        'DELETE /api/saved/items/i1?',
        'PUT /api/saved/items/i1/place?',
      ]);
      expect(jsonDecode(bodies[3]), {'list': 'Books'});
      expect(jsonDecode(bodies.last)['address'], 'Via Roma 12');
    });
  });

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
        (service) => service.listConversations(),
        (service) => service.getConversation('c1'),
        (service) => service.search('atlas'),
        (service) => service.listTasks(done: false),
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
        (request) => _jsonResponse(request, 200, {
          'conversations': [
            {'id': 42, 'started_at': 'not-a-date', 'duration_s': '100'},
          ],
          'total': 1,
        }),
      );

      await _expectApiException(
        service.listConversations(),
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

  group('offline copy', () {
    late MemoryResponseCache cache;
    late bool offline;
    late ApiService service;
    final page = {
      'conversations': [
        {'id': 'c1', 'started_at': '2026-10-15T08:00:00Z', 'title': 'Pranzo'},
      ],
      'total': 1,
    };

    setUp(() {
      cache = MemoryResponseCache()
        ..clock = () => DateTime.utc(2026, 10, 15, 12, 32);
      offline = false;
      offlineDataSince.value = null;
      service = ApiService(
        client: _StubClient((request) {
          if (offline) throw http.ClientException('no network', request.url);
          return _jsonResponse(request, 200, page);
        }),
        credentialStore: _FakeCredentialStore(),
        cache: cache,
      );
    });

    tearDown(() => offlineDataSince.value = null);

    test('the last answer is shown offline, and the banner knows since when',
        () async {
      expect((await service.listConversations()).single.title, 'Pranzo');
      await Future<void>.delayed(
          Duration.zero); // the copy is written in the background
      expect(offlineDataSince.value, isNull);

      offline = true;
      expect((await service.listConversations()).single.title, 'Pranzo');
      expect(offlineDataSince.value, DateTime.utc(2026, 10, 15, 12, 32));

      offline = false;
      await service.listConversations();
      expect(offlineDataSince.value, isNull);
    });

    test('without a copy the error stays an error', () async {
      offline = true;
      await _expectApiException(service.listConversations(), code: 'offline');
    });

    test('the cache view reads only the copy', () async {
      await _expectApiException(service.cacheView().listConversations(),
          code: 'offline');
      await service.listConversations();
      await Future<void>.delayed(Duration.zero);
      offline = true;
      expect((await service.cacheView().listConversations()).single.id, 'c1');
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

    test('open tasks ask the server for done=false and skip nameless ones',
        () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {
          'entities': [
            {
              'id': 'open',
              'name': 'Call Ada',
              'metadata_': {'due_date': '2026-10-14'},
              'source_text': '[Tu] Chiamo Ada.',
              'conversation_id': 'c1',
              'created_at': '2026-10-14T09:30:00Z',
            },
            {
              'id': 'blank',
              'name': ' ',
              'metadata_': {},
              'created_at': '2026-10-14T09:30:00Z'
            },
          ],
          'total': 2,
        });
      });

      final tasks = await service.listTasks(done: false);

      expect(captured.url.toString(),
          'https://echo.test/api/entities/tasks?done=false&limit=200');
      expect(tasks.map((task) => task.id), ['open']);
      expect(tasks.single.dueDate, DateTime(2026, 10, 14));
      expect(tasks.single.sourceText, '[Tu] Chiamo Ada.');
    });

    test('completing a task sends the full metadata with done true', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {'id': 'task-1'});
      });

      await service.setTaskDone(
        const TaskItem(
            id: 'task-1', name: 'Call Ada', metadata: {'priority': 'high'}),
        true,
      );

      expect(captured.method, 'PATCH');
      expect(captured.url.toString(), 'https://echo.test/api/entities/task-1');
      expect(jsonDecode(captured.body), {
        'metadata_': {'priority': 'high', 'done': true},
      });
    });

    test('search encodes the query', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(
            request, 200, {'conversations': [], 'entities': []});
      });

      final results = await service.search(' 50% off & more ');

      expect(captured.url.query, 'q=50%25+off+%26+more');
      expect(results.isEmpty, isTrue);
    });

    test('people and pending actions parse their lists', () async {
      final service = _service((request) => switch (request.url.path) {
            '/api/people' => _jsonResponse(request, 200, [
                {
                  'id': 'p1',
                  'name': 'Ada',
                  'conversation_count': 2,
                  'open_task_count': 1
                },
                {'id': 'p2', 'name': ' '},
              ]),
            _ => _jsonResponse(request, 200, [
                {
                  'id': 'a1',
                  'summary': 'Send the budget',
                  'tool': 'GMAIL_SEND_EMAIL',
                  'app': 'Gmail',
                  'source': 'voice',
                  'session_id': null,
                  'created_at': '2026-10-14T09:30:00Z',
                  'expires_at': '2026-10-14T10:00:00Z',
                },
              ]),
          });

      final people = await service.listPeople();
      final pending = await service.listPendingActions();

      expect(people.map((p) => p.name), ['Ada']);
      expect(people.single.openTaskCount, 1);
      expect(pending.single.app, 'Gmail');
      expect(pending.single.source, 'voice');
    });
  });

  group('streamed answers', () {
    Future<http.StreamedResponse> sse(
        http.BaseRequest request, List<String> chunks) async {
      return http.StreamedResponse(
        Stream.fromIterable(chunks.map(utf8.encode)),
        200,
        request: request,
        headers: const {'content-type': 'text/event-stream'},
      );
    }

    const done = '{"answer":"Marco suggested sushi.","sources":[],'
        '"session_id":"s1","date_filter":null,"pending_action":null}';

    test('pieces arrive in order, even split across network chunks', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return sse(request, [
          'event: token\ndata: {"text": "Marco "}\n\nevent: tok',
          'en\ndata: {"text": "suggested sushi."}\n\n',
          'event: done\ndata: $done\n\n',
        ]);
      });
      final pieces = <String>[];

      final response = await service.query('Marco?',
          clientRequestId: 'r1', onToken: pieces.add);

      expect(captured.url.toString(), 'https://echo.test/api/query/stream');
      expect(jsonDecode(captured.body), {
        'question': 'Marco?',
        'top_k': 5,
        'client_request_id': 'r1',
      });
      expect(pieces, ['Marco ', 'suggested sushi.']);
      expect(response.answer, 'Marco suggested sushi.');
      expect(response.sessionId, 's1');
    });

    test('an error event is a typed ApiException', () async {
      final service = _service((request) => sse(request, [
            'event: token\ndata: {"text": "Half"}\n\n',
            'event: error\ndata: {"status": 500, "detail": "Echo could not answer."}\n\n',
          ]));

      final error = await _expectApiException(
        service.query('Marco?', onToken: (_) {}),
        statusCode: 500,
        code: 'server',
      );
      expect(error.message, 'Echo could not answer.');
    });

    test('a 409 before the stream is the usual conflict', () async {
      final service = _service(
        (request) =>
            _jsonResponse(request, 409, {'detail': 'Still working on it'}),
      );

      await _expectApiException(
        service.query('Marco?', onToken: (_) {}),
        statusCode: 409,
        code: 'conflict',
      );
    });

    test('a stream that ends without the answer is offline', () async {
      final service = _service((request) => sse(request, [
            'event: token\ndata: {"text": "Half"}\n\n',
          ]));

      await _expectApiException(service.query('Marco?', onToken: (_) {}),
          code: 'offline');
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

    test('confirmPendingAction accepts an unknown outcome', () async {
      final service = _service((request) => _jsonResponse(request, 200, {
            'status': 'unknown',
            'message': 'Check Gmail before trying again.',
          }));

      final result = await service.confirmPendingAction('p1');

      expect(result.status, 'unknown');
      expect(result.unknown, isTrue);
      expect(result.failed, isFalse);
    });

    test('confirmPendingAction rejects an unexpected status', () async {
      final service = _service((request) => _jsonResponse(request, 200, {
            'status': 'maybe',
            'message': '',
          }));

      await _expectApiException(
        service.confirmPendingAction('p1'),
        code: 'invalid_response',
      );
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

    test('query sends client_request_id and uses the long query timeout',
        () async {
      late http.Request captured;
      final service = _service(
        (request) async {
          captured = request as http.Request;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return _jsonResponse(request, 200, {
            'answer': 'Done',
            'session_id': 's1',
            'sources': <Object?>[],
          });
        },
        requestTimeout: const Duration(milliseconds: 1),
        queryTimeout: const Duration(seconds: 5),
      );

      final response = await service.query(
        'send it',
        sessionId: 's1',
        clientRequestId: 'req-1',
      );

      expect(response.answer, 'Done');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['client_request_id'], 'req-1');
      expect(body['session_id'], 's1');
    });

    test('query without a client request id omits the field', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {
          'answer': 'Hi',
          'session_id': 's1',
          'sources': <Object?>[],
        });
      });

      await service.query('hello');

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body.containsKey('client_request_id'), isFalse);
    });

    test('query times out after the query timeout', () async {
      final service = _service(
        (request) => Completer<http.StreamedResponse>().future,
        queryTimeout: const Duration(milliseconds: 1),
      );

      await _expectApiException(service.query('slow'), code: 'timeout');
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

  group('the phone', () {
    test('commands: photos for the wearable and actions for this iPhone', () async {
      late http.BaseRequest captured;
      final service = _service((request) {
        captured = request;
        return _jsonResponse(request, 200, {
          'commands': [
            {'type': 'take_photo', 'photo_id': 'p1', 'expires_at': 'x'},
            {
              'type': 'phone_action',
              'id': 'c1',
              'tool': 'APPLEREMINDERS_CREATE_REMINDER',
              'arguments': {'title': 'Latte'},
              'expires_at': 'x',
            },
            {'type': 'something_newer', 'expires_at': 'x'},
          ],
        });
      });

      final commands = await service.getDeviceCommands(wait: const Duration(seconds: 5));

      expect(captured.url.path, '/api/device/commands');
      expect(captured.url.queryParameters, {'wait': '5'});
      expect(commands, [isA<TakePhotoCommand>(), isA<PhoneActionCommand>()]);
    });

    test('a result goes back to its command, accepted on 204', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _response(request, 204);
      });

      await service.sendCommandResult('c1', {'ok': true, 'data': {'id': 'r1'}});

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/device/commands/c1/result');
      expect(jsonDecode(captured.body), {'ok': true, 'data': {'id': 'r1'}});
    });

    test('which iPhone apps are on', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {'reminders': true, 'calendar': false});
      });

      await service.reportPhoneApps(reminders: true, calendar: false);

      expect(captured.method, 'PUT');
      expect(captured.url.path, '/api/device/phone-apps');
      expect(jsonDecode(captured.body), {'reminders': true, 'calendar': false});
    });

    test('notifications are asked with the iPhone calendar events', () async {
      late http.Request captured;
      final service = _service((request) {
        captured = request as http.Request;
        return _jsonResponse(request, 200, {'notifications': <Object?>[]});
      });

      await service.getUpcomingNotifications(
        briefings: true,
        promises: false,
        evening: false,
        phoneEvents: [
          {'id': 'e1', 'title': 'Call'},
        ],
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/notifications/upcoming');
      expect(jsonDecode(captured.body), {
        'briefings': true,
        'promises': false,
        'evening': false,
        'phone_events': [
          {'id': 'e1', 'title': 'Call'},
        ],
      });
    });
  });
}

ApiService _service(
  Future<http.StreamedResponse> Function(http.BaseRequest) handler, {
  Duration requestTimeout = const Duration(seconds: 10),
  Duration uploadTimeout = const Duration(seconds: 20),
  Duration queryTimeout = const Duration(seconds: 90),
}) {
  return ApiService(
    client: _StubClient(handler),
    credentialStore: _FakeCredentialStore(),
    requestTimeout: requestTimeout,
    uploadTimeout: uploadTimeout,
    queryTimeout: queryTimeout,
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
