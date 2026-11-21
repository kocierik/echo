import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/assistant.dart';
import 'package:echo_app/models/chat_session.dart';
import 'package:echo_app/models/photo.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/chat/chat_controller.dart';
import 'package:echo_app/services/device/photo_service.dart';
import 'package:echo_app/services/chat/voice_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _languageTests();
  _assistantTests();

  late _FakeChatApi api;
  late _FakeVoiceInput voice;
  late ChatController controller;
  late List<Duration> waits;

  setUp(() {
    api = _FakeChatApi();
    voice = _FakeVoiceInput();
    waits = [];
    var requestIds = 0;
    controller = ChatController(
      api: api,
      voiceInput: voice,
      clock: () => DateTime.parse('2026-10-02T12:00:00Z'),
      requestIdFactory: () => 'req-${++requestIds}',
      wait: (pause) async => waits.add(pause),
    );
  });

  tearDown(() => controller.dispose());

  group('photos', () {
    late _FakePhotoTaker taker;

    setUp(() {
      taker = _FakePhotoTaker();
      controller.dispose();
      controller = ChatController(
        api: api,
        voiceInput: voice,
        clock: () => DateTime.parse('2026-10-02T12:00:00Z'),
        photoTaker: taker,
      );
    });

    test('the typed text is the question, and the answer comes with the photo', () async {
      api.details['voice'] = _detail(
        id: 'voice',
        title: 'Voice requests',
        messages: const [
          ChatSessionMessage(role: 'user', content: 'Che pianta è?', photoId: 'p1'),
          ChatSessionMessage(role: 'assistant', content: 'È un ficus.', photoId: 'p1'),
        ],
      );
      controller.setComposerText('Che pianta è?');

      final taking = controller.takePhoto();
      expect(controller.state.sending, isTrue);
      expect(controller.state.messages.last.text, 'Che pianta è?');
      expect(controller.state.composerText, isEmpty);
      await taking;

      expect(taker.questions, ['Che pianta è?']);
      expect(controller.state.sessionId, 'voice');
      expect(controller.state.messages.last.photoId, 'p1');
      expect(controller.state.messages.last.text, 'È un ficus.');
      expect(controller.state.sending, isFalse);
    });

    test('without text it is a plain photo', () async {
      api.details['voice'] = _detail(id: 'voice', title: 'Voice requests', messages: const []);
      await controller.takePhoto();
      expect(taker.questions, [null]);
    });

    test('says why when the wearable cannot take it, and keeps the question', () async {
      taker.error = const PhotoUnavailableException('muted');
      controller.setComposerText('Cosa vedi?');

      await controller.takePhoto();

      expect(controller.state.error, contains('muted'));
      expect(controller.state.messages, isEmpty);
      expect(controller.state.composerText, 'Cosa vedi?');
      expect(controller.state.sending, isFalse);
    });

    test('a cancelled phone camera leaves nothing behind', () async {
      taker.error = const PhotoCancelledException();
      controller.setComposerText('Cos\'è?');

      await controller.takePhoto();

      expect(controller.state.messages, isEmpty);
      expect(controller.state.error, isNull);
      expect(controller.state.sending, isFalse);
      expect(controller.state.composerText, 'Cos\'è?');
    });

    test('no camera button without a photo taker', () {
      final plain = ChatController(api: api, voiceInput: voice);
      expect(plain.canTakePhotos, isFalse);
      expect(controller.canTakePhotos, isTrue);
      plain.dispose();
    });
  });

  group('pending actions', () {
    const action = PendingAction(id: 'act-1', summary: 'Send email to Ann');

    Future<void> withPending() async {
      api.queryHandler = (_, __) async => QueryResponse(
            answer: 'Shall I send it?',
            sessionId: 'session-1',
            sources: const [],
            pendingAction: action,
          );
      await controller.send('Email Ann');
    }

    ApiException apiError(String code, int status) => ApiException(
          statusCode: status,
          code: code,
          message: 'msg-$code',
          retryable: false,
        );

    PendingAction card() => controller.state.messages
        .firstWhere((m) => m.pendingAction != null)
        .pendingAction!;

    test('query response keeps the pending action on the assistant message',
        () async {
      await withPending();

      expect(controller.state.messages.last.pendingAction?.id, 'act-1');
    });

    test('confirm marks executed and appends the server message', () async {
      await withPending();
      await controller.confirmAction('act-1');

      expect(api.confirms, ['act-1']);
      expect(card().status, 'executed');
      expect(controller.state.messages.last.text, 'Done.');
      expect(controller.state.messages.last.isUser, isFalse);
      expect(controller.state.busyActionIds, isEmpty);
    });

    test('a failed result marks the card failed regardless of language',
        () async {
      await withPending();
      api.confirmHandler = (_) async => const ConfirmResult(
            status: 'failed',
            message: 'Non è andata a buon fine: nessuna rete',
          );
      await controller.confirmAction('act-1');

      expect(card().status, 'failed');
      expect(
        controller.state.messages.last.text,
        'Non è andata a buon fine: nessuna rete',
      );
    });

    test('an unknown result marks the card unknown with the server message',
        () async {
      await withPending();
      api.confirmHandler = (_) async => const ConfirmResult(
            status: 'unknown',
            message: 'Check Gmail before trying again.',
          );
      await controller.confirmAction('act-1');

      expect(card().status, 'unknown');
      expect(
        controller.state.messages.last.text,
        'Check Gmail before trying again.',
      );
      expect(controller.state.busyActionIds, isEmpty);
    });

    test('an executed result with an unusual message is still executed',
        () async {
      await withPending();
      api.confirmHandler = (_) async =>
          const ConfirmResult(status: 'executed', message: 'Fatto.');
      await controller.confirmAction('act-1');

      expect(card().status, 'executed');
    });

    test('a second confirm while in flight is ignored', () async {
      await withPending();
      final pending = Completer<ConfirmResult>();
      api.confirmHandler = (_) => pending.future;

      final first = controller.confirmAction('act-1');
      final second = controller.confirmAction('act-1');
      await controller.cancelAction('act-1');

      expect(controller.state.busyActionIds, {'act-1'});
      pending.complete(const ConfirmResult(status: 'executed', message: 'Done.'));
      await Future.wait([first, second]);

      expect(api.confirms, ['act-1']);
      expect(api.cancels, isEmpty);
      expect(controller.state.busyActionIds, isEmpty);
    });

    test('410 expires the card with a message', () async {
      await withPending();
      api.confirmHandler = (_) => Future.error(apiError('expired', 410));
      await controller.confirmAction('act-1');

      expect(card().status, 'expired');
      expect(
        controller.state.messages.last.text,
        'This request expired. Ask again.',
      );
    });

    test('409 shows the request as already handled', () async {
      await withPending();
      api.confirmHandler = (_) => Future.error(apiError('conflict', 409));
      await controller.confirmAction('act-1');

      expect(card().status, 'resolved');
      expect(
        controller.state.messages.last.text,
        'This request was already handled.',
      );
    });

    test('other errors keep the card pending and surface the error',
        () async {
      await withPending();
      api.confirmHandler = (_) => Future.error(apiError('server', 500));
      await controller.confirmAction('act-1');

      expect(card().status, isNull);
      expect(controller.state.error, 'msg-server');
      expect(controller.state.busyActionIds, isEmpty);

      api.confirmHandler = null;
      await controller.confirmAction('act-1');
      expect(api.confirms, ['act-1', 'act-1']);
    });

    test('cancel marks cancelled and mirrors "Cancelled."', () async {
      await withPending();
      await controller.cancelAction('act-1');

      expect(api.cancels, ['act-1']);
      expect(card().status, 'cancelled');
      expect(controller.state.messages.last.text, 'Cancelled.');
    });

    test('resolved actions cannot be confirmed again', () async {
      await withPending();
      await controller.confirmAction('act-1');
      await controller.confirmAction('act-1');

      expect(api.confirms, ['act-1']);
    });

    test('loaded sessions keep pending actions', () async {
      api.details['s'] = _detail(id: 's', title: 'Voice requests', messages: [
        const ChatSessionMessage(
          role: 'assistant',
          content: 'Delete it?',
          pendingAction: PendingAction(
            id: 'act-2',
            summary: 'Delete file',
            status: 'pending',
          ),
        ),
      ]);
      await controller.loadSession('s');

      expect(controller.state.messages.single.pendingAction?.id, 'act-2');
    });
  });

  test('empty submit is a no-op', () async {
    await controller.send('   ');

    expect(api.queries, isEmpty);
    expect(controller.state.messages, isEmpty);
    expect(controller.state.sending, isFalse);
  });

  test('typed send adds user immediately and serializes duplicate sends',
      () async {
    final response = Completer<QueryResponse>();
    api.queryHandler = (_, __) => response.future;

    final first = controller.send('What did I decide?');
    final duplicate = controller.send('A duplicate');

    expect(controller.state.messages.single.text, 'What did I decide?');
    expect(controller.state.messages.single.isUser, isTrue);
    expect(controller.state.messages.single.timestamp,
        DateTime.parse('2026-10-02T12:00:00Z'));
    expect(controller.state.sending, isTrue);
    expect(api.queries, ['What did I decide?']);

    response.complete(_response(answer: 'Use the smaller launch scope.'));
    await Future.wait([first, duplicate]);

    expect(controller.state.messages.last.text, 'Use the smaller launch scope.');
    expect(controller.state.messages.last.index, 1);
    expect(controller.state.sessionId, 'session-1');
    expect(controller.state.sending, isFalse);
  });

  test('success maps real source text and ids without fabricating urls',
      () async {
    api.queryHandler = (_, __) async => _response(
          answer: '**Decision:** ship Friday.',
          sources: const [
            {
              'chunk_id': 'chunk-1',
              'conversation_id': 'conversation-1',
              'text': 'We agreed to ship Friday.',
              'similarity': 0.91,
            },
          ],
        );

    await controller.send('When do we ship?');

    final assistant = controller.state.messages.last;
    expect(assistant.sources.single.label, 'Source 1');
    expect(assistant.sources.single.text, 'We agreed to ship Friday.');
    expect(assistant.sources.single.chunkId, 'chunk-1');
    expect(assistant.sources.single.url, isNull);
  });

  test('a streamed answer grows, then becomes the message', () async {
    final answer = Completer<QueryResponse>();
    api
      ..streamPieces = ['Marco ', 'suggested ', 'sushi.']
      ..queryHandler = (_, __) => answer.future;

    final sending = controller.send('What did Marco say?');
    await pumpEventQueue();
    expect(controller.state.sending, isTrue);
    expect(controller.state.streamingText, 'Marco suggested sushi.');

    answer.complete(_response(answer: 'Marco suggested sushi.'));
    await sending;
    expect(controller.state.streamingText, isNull);
    expect(controller.state.messages.last.text, 'Marco suggested sushi.');
    expect(controller.state.messages.last.isUser, isFalse);
  });

  test('sources say their conversation and open it', () async {
    api.queryHandler = (_, __) async => QueryResponse(
          answer: 'Sushi.',
          sessionId: 's1',
          sources: const [
            {
              'conversation_id': 'c1',
              'chunk_id': 'k1',
              'text': 'Marco suggested sushi.',
              'title': 'Lunch with Marco',
              'started_at': '2026-10-01T12:30:00Z',
            },
            {'conversation_id': 'c2', 'chunk_id': 'k2', 'text': 'Untitled', 'started_at': '2026-10-02T09:00:00Z'},
            {'chunk_id': 'k3', 'text': 'Old shape'},
          ],
        );

    await controller.send('What did Marco suggest?');

    final sources = controller.state.messages.last.sources;
    expect(sources.map((s) => s.label), [
      'Lunch with Marco · Yesterday',
      'Conversation · Today',
      'Source 3',
    ]);
    expect(sources.first.conversationId, 'c1');
    expect(sources.last.conversationId, isNull);
  });

  test('pages from the web come first, labelled by title or site, and open', () async {
    api.queryHandler = (_, __) async => QueryResponse(
          answer: 'Domani sole.',
          sessionId: 's1',
          sources: const [
            {'conversation_id': 'c1', 'chunk_id': 'k1', 'text': 'Pioveva.', 'title': 'Gita'},
          ],
          webSources: const [
            {'title': 'Meteo Milano', 'url': 'https://www.ilmeteo.it/meteo/Milano'},
            {'title': null, 'url': 'https://3bmeteo.com/milano'},
          ],
        );

    await controller.send('Che tempo fa domani a Milano?');

    final sources = controller.state.messages.last.sources;
    expect(sources.map((s) => s.label), ['Meteo Milano', '3bmeteo.com', 'Gita']);
    expect(sources.first.text, 'ilmeteo.it');
    expect(sources.first.url, Uri.parse('https://www.ilmeteo.it/meteo/Milano'));
    expect(sources.last.url, isNull);
  });

  test('web pages kept in the history show again', () async {
    api.details['s9'] = _detail(id: 's9', title: 'Meteo', messages: [
      ChatSessionMessage.fromJson(const {'role': 'user', 'content': 'Meteo?', 'timestamp': null}),
      ChatSessionMessage.fromJson(const {
        'role': 'assistant',
        'content': 'Sole.',
        'timestamp': null,
        'citations': [
          {'title': 'Meteo Milano', 'url': 'https://www.ilmeteo.it/meteo/Milano'},
        ],
      }),
    ]);

    await controller.loadSession('s9');

    final source = controller.state.messages.last.sources.single;
    expect(source.label, 'Meteo Milano');
    expect(source.text, 'ilmeteo.it');
  });

  test('a failure clears the partial answer', () async {
    api
      ..streamPieces = ['Half']
      ..queryHandler = (_, __) => Future.error(Exception('offline'));

    await controller.send('What did Marco say?');

    expect(controller.state.streamingText, isNull);
    expect(controller.state.messages.single.failed, isTrue);
  });

  test('failure preserves and marks the user question for retry', () async {
    api.queryHandler = (_, __) => Future.error(Exception('offline'));

    await controller.send('Remember this question');

    expect(controller.state.messages.single.text, 'Remember this question');
    expect(controller.state.messages.single.failed, isTrue);
    expect(controller.state.error, contains('offline'));
    expect(controller.state.canRetry, isTrue);
  });

  test('retry reuses the failed user question without duplicating it', () async {
    var attempts = 0;
    api.queryHandler = (_, __) async {
      attempts++;
      if (attempts == 1) throw Exception('offline');
      return _response(answer: 'Recovered');
    };

    await controller.send('Try this');
    await controller.retryLastFailed();

    expect(api.queries, ['Try this', 'Try this']);
    expect(
      controller.state.messages.where((message) => message.isUser),
      hasLength(1),
    );
    expect(controller.state.messages.first.failed, isFalse);
    expect(controller.state.messages.last.text, 'Recovered');
  });

  test('each message gets its own request id and retry reuses it', () async {
    var attempts = 0;
    api.queryHandler = (_, __) async {
      attempts++;
      if (attempts == 2) throw Exception('offline');
      return _response(answer: 'Answer $attempts');
    };

    await controller.send('First');
    await controller.send('Second');
    await controller.retryLastFailed();

    expect(api.queries, ['First', 'Second', 'Second']);
    expect(api.queryRequestIds, ['req-1', 'req-2', 'req-2']);
    expect(controller.state.messages.last.text, 'Answer 3');
  });

  test('a timed-out request waits for the answer still being worked on', () async {
    // The phone gave up while the server went on: the same request id gets 409
    // until the answer is stored, then the answer itself
    var attempts = 0;
    api.queryHandler = (_, __) async {
      attempts++;
      if (attempts == 1) throw _timeout;
      if (attempts < 4) throw _stillWorking;
      return _response(answer: 'Sent to Ann');
    };

    await controller.send('Email Ann');

    expect(api.queries, ['Email Ann', 'Email Ann', 'Email Ann', 'Email Ann']);
    expect(api.queryRequestIds.toSet(), {'req-1'});
    expect(waits, everyElement(ChatController.stillWorkingPause));
    expect(controller.state.error, isNull);
    expect(controller.state.messages.first.failed, isFalse);
    expect(controller.state.messages.last.text, 'Sent to Ann');
    expect(controller.state.sending, isFalse);
  });

  test('409 "Still working on it" for too long shows a friendly message', () async {
    api.queryHandler = (_, __) => Future.error(_stillWorking);

    await controller.send('Email Ann');

    expect(api.queries, hasLength(ChatController.stillWorkingRetries + 1));
    expect(
      controller.state.error,
      'Echo is still working on your last request.',
    );
    expect(controller.state.messages.single.failed, isTrue);
    expect(controller.state.sending, isFalse);
  });

  test('waiting stops when another chat is opened', () async {
    api.details['history'] = _detail(id: 'history', title: 'History', messages: const []);
    api.queryHandler = (_, __) async {
      if (api.queries.length == 2) await controller.loadSession('history');
      throw _stillWorking;
    };

    await controller.send('Email Ann');

    expect(api.queries, hasLength(2));
    expect(controller.state.sessionId, 'history');
    expect(controller.state.error, isNull);
  });

  test('session switch discards a stale send response', () async {
    final query = Completer<QueryResponse>();
    api.queryHandler = (_, __) => query.future;
    api.details['history'] = _detail(
      id: 'history',
      title: 'Loaded history',
      messages: const [
        ChatSessionMessage(role: 'assistant', content: 'Historical answer'),
      ],
    );

    final send = controller.send('Stale question');
    await controller.loadSession('history');
    query.complete(_response(answer: 'Stale answer'));
    await send;

    expect(controller.state.sessionId, 'history');
    expect(controller.state.messages.single.text, 'Historical answer');
    expect(controller.state.sending, isFalse);
  });

  test('new chat discards a stale session response', () async {
    final detail = Completer<ChatSessionDetail>();
    api.detailHandler = (_) => detail.future;

    final load = controller.loadSession('old');
    controller.newChat();
    detail.complete(_detail(id: 'old', title: 'Old'));
    await load;

    expect(controller.state.sessionId, isNull);
    expect(controller.state.messages, isEmpty);
    expect(controller.state.loadingSession, isFalse);
  });

  test('newer session load discards an older session response', () async {
    final older = Completer<ChatSessionDetail>();
    final newer = Completer<ChatSessionDetail>();
    api.detailHandler = (id) => id == 'older' ? older.future : newer.future;

    final olderLoad = controller.loadSession('older');
    final newerLoad = controller.loadSession('newer');
    newer.complete(_detail(
      id: 'newer',
      title: 'Newer',
      messages: const [
        ChatSessionMessage(role: 'assistant', content: 'Current history'),
      ],
    ));
    await newerLoad;
    older.complete(_detail(
      id: 'older',
      title: 'Older',
      messages: const [
        ChatSessionMessage(role: 'assistant', content: 'Stale history'),
      ],
    ));
    await olderLoad;

    expect(controller.state.sessionId, 'newer');
    expect(controller.state.messages.single.text, 'Current history');
  });

  test('complete history stays in backend order with assistant indexes',
      () async {
    api.details['history'] = _detail(
      id: 'history',
      title: 'Planning',
      messages: const [
        ChatSessionMessage(
          role: 'user',
          content: 'First user',
          timestamp: null,
        ),
        ChatSessionMessage(
          role: 'assistant',
          content: 'First assistant',
          citations: [
            {'chunk_id': 'chunk-2', 'text': 'A saved source'},
          ],
        ),
        ChatSessionMessage(role: 'user', content: 'Second user'),
        ChatSessionMessage(role: 'assistant', content: 'Second assistant'),
      ],
    );

    await controller.loadSession('history');

    expect(
      controller.state.messages.map((message) => message.text),
      ['First user', 'First assistant', 'Second user', 'Second assistant'],
    );
    expect(
      controller.state.messages.map((message) => message.index),
      [null, 1, null, 2],
    );
    expect(controller.state.messages[1].sources.single.text, 'A saved source');
    expect(controller.state.title, 'Planning');
  });

  test('deleting the active session starts a new chat', () async {
    api.details['active'] = _detail(
      id: 'active',
      title: 'Active',
      messages: const [
        ChatSessionMessage(role: 'assistant', content: 'Loaded'),
      ],
    );
    await controller.loadSession('active');

    await controller.deleteSession('active');

    expect(api.deletes, ['active']);
    expect(controller.state.sessionId, isNull);
    expect(controller.state.messages, isEmpty);
  });

  test('voice unavailable and denied permission expose errors', () async {
    voice.isAvailable = false;
    await controller.startVoice();
    expect(controller.state.listening, isFalse);
    expect(controller.state.error, 'Voice input is unavailable.');

    voice.isAvailable = true;
    voice.permissionGranted = false;
    await controller.startVoice();
    expect(controller.state.listening, isFalse);
    expect(controller.state.error, 'Microphone permission was denied.');
  });

  test('voice partial and final update draft and stop never auto-sends',
      () async {
    await controller.startVoice();
    expect(controller.state.listening, isTrue);

    voice.emitPartial('partial words');
    expect(controller.state.composerText, 'partial words');
    voice.emitFinal('final question');
    expect(controller.state.composerText, 'final question');
    expect(api.queries, isEmpty);

    await controller.stopVoice();
    expect(controller.state.listening, isFalse);
    expect(voice.stopCalls, 1);
    expect(api.queries, isEmpty);
  });

  test('released before dictation started: it never starts', () async {
    final starting = controller.startVoice();  // still checking the permission
    await controller.stopVoice();
    await starting;

    expect(controller.state.listening, isFalse);
    voice.emitPartial('ignored');
    expect(controller.state.composerText, isEmpty);
  });

  test('dispose cancels voice and ignores later callbacks', () async {
    await controller.startVoice();
    controller.dispose();
    voice.emitPartial('ignored');
    voice.emitFinal('also ignored');
    await Future<void>.delayed(Duration.zero);

    expect(voice.cancelCalls, 1);
    expect(controller.state.composerText, isEmpty);

    controller = ChatController(api: api, voiceInput: voice);
  });
}

const _stillWorking = ApiException(
  statusCode: 409,
  code: 'conflict',
  message: 'Still working on it',
  retryable: false,
);

const _timeout = ApiException(
  statusCode: null,
  code: 'timeout',
  message: 'The request timed out.',
  retryable: true,
);

QueryResponse _response({
  required String answer,
  List<Map<String, dynamic>> sources = const [],
}) {
  return QueryResponse(
    answer: answer,
    sessionId: 'session-1',
    sources: sources,
  );
}

ChatSessionDetail _detail({
  required String id,
  required String? title,
  List<ChatSessionMessage> messages = const [],
}) {
  return ChatSessionDetail(
    id: id,
    title: title,
    messages: messages,
    createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
    updatedAt: DateTime.parse('2026-10-01T09:31:00Z'),
  );
}

final class _FakeChatApi implements ChatApi {
  final queries = <String>[];
  final querySessionIds = <String?>[];
  final queryRequestIds = <String?>[];
  final queryAssistantIds = <String?>[];
  final deletes = <String>[];
  final details = <String, ChatSessionDetail>{};

  Future<QueryResponse> Function(String question, String? sessionId)?
      queryHandler;
  Future<ChatSessionDetail> Function(String id)? detailHandler;

  /// Pieces passed to onToken before the answer is returned.
  List<String> streamPieces = const [];

  @override
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
    String? assistantId,
    void Function(String piece)? onToken,
  }) {
    streamPieces.forEach(onToken ?? (_) {});
    queries.add(question);
    querySessionIds.add(sessionId);
    queryRequestIds.add(clientRequestId);
    queryAssistantIds.add(assistantId);
    return queryHandler?.call(question, sessionId) ??
        Future.value(_response(answer: 'Answer'));
  }

  @override
  Future<ChatSessionDetail> getSessionDetail(String id) {
    return detailHandler?.call(id) ?? Future.value(details[id]!);
  }

  @override
  Future<List<ChatSessionSummary>> getSessions() async => const [];

  @override
  Future<void> deleteSession(String id) async {
    deletes.add(id);
  }

  final confirms = <String>[];
  final cancels = <String>[];
  Future<ConfirmResult> Function(String id)? confirmHandler;
  Future<void> Function(String id)? cancelHandler;

  @override
  Future<ConfirmResult> confirmPendingAction(String id) {
    confirms.add(id);
    return confirmHandler?.call(id) ??
        Future.value(const ConfirmResult(status: 'executed', message: 'Done.'));
  }

  @override
  Future<void> cancelPendingAction(String id) {
    cancels.add(id);
    return cancelHandler?.call(id) ?? Future.value();
  }
}



void _languageTests() {
  test('dictation uses the language the user speaks', () async {
    final voice = _FakeVoiceInput();
    final controller = ChatController(
      api: _FakeChatApi(),
      voiceInput: voice,
      spokenLanguage: () async => 'it',
    );

    await controller.startVoice();

    expect(voice.language, 'it');
  });
}

final class _FakeVoiceInput implements VoiceInput {
  bool isAvailable = true;
  bool permissionGranted = true;
  int stopCalls = 0;
  int cancelCalls = 0;
  void Function(String)? _onPartial;
  void Function(String)? _onFinal;

  @override
  Future<bool> available() async => isAvailable;

  @override
  Future<bool> request() async => permissionGranted;

  String? language;

  @override
  Future<void> start({
    required void Function(String) onPartial,
    required void Function(String) onFinal,
    String? language,
  }) async {
    _onPartial = onPartial;
    _onFinal = onFinal;
    this.language = language;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  void emitPartial(String text) => _onPartial?.call(text);

  void emitFinal(String text) => _onFinal?.call(text);
}

final class _FakePhotoTaker implements PhotoTaker {
  final questions = <String?>[];
  Object? error;

  final fromLibrary = <bool>[];

  @override
  Future<PhotoInfo> takePhoto({String? question, String? chatSessionId}) =>
      throw UnimplementedError('Ask uses the phone');

  @override
  Future<PhotoInfo> phonePhoto({
    required bool fromLibrary,
    String? question,
    String? chatSessionId,
  }) async {
    if (error != null) throw error!;
    questions.add(question);
    this.fromLibrary.add(fromLibrary);
    return PhotoInfo(id: 'p1', status: 'requested', chatSessionId: chatSessionId ?? 'voice');
  }

  @override
  Future<PhotoInfo> waitForAnswer(String photoId) async =>
      PhotoInfo(id: photoId, status: 'done', answer: 'È un ficus.');
}

void _assistantTests() {
  const diet = ChatAssistant(id: 'a1', name: 'Dieta', emoji: '🥗');

  test('a new chat with an assistant asks it, and the chat keeps it', () async {
    final api = _FakeChatApi()
      ..queryHandler = (_, __) async =>
          QueryResponse(answer: 'Minestrone.', sessionId: 's1', sources: []);
    final controller = ChatController(api: api, voiceInput: _FakeVoiceInput());
    addTearDown(controller.dispose);

    controller.newChat(assistant: diet);
    await controller.send('cosa mangio stasera?');
    await controller.send('e domani?');

    // The first question names it; the chat it started then carries it
    expect(api.queryAssistantIds, ['a1', null]);
    expect(api.querySessionIds, [null, 's1']);
    expect(controller.state.assistant?.name, 'Dieta');
  });

  test('choosing an assistant only before the first question', () async {
    final controller = ChatController(api: _FakeChatApi(), voiceInput: _FakeVoiceInput());
    addTearDown(controller.dispose);

    controller.newChat();
    controller.chooseAssistant(diet);
    expect(controller.state.assistant, diet);
    controller.chooseAssistant(null);
    expect(controller.state.assistant, isNull);

    await controller.send('ciao');
    controller.chooseAssistant(diet);
    expect(controller.state.assistant, isNull);
  });

  test('a chat opened from history shows its assistant', () async {
    final api = _FakeChatApi();
    api.details['s1'] = ChatSessionDetail(
      id: 's1',
      title: 'Cena',
      messages: const [],
      createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
      updatedAt: DateTime.parse('2026-10-01T09:31:00Z'),
      assistant: diet,
    );
    final controller = ChatController(api: api, voiceInput: _FakeVoiceInput());
    addTearDown(controller.dispose);

    await controller.loadSession('s1');

    expect(controller.state.assistant, diet);
    controller.newChat();
    expect(controller.state.assistant, isNull);
  });
}
