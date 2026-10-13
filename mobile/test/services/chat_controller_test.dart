import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/chat_session.dart';
import 'package:echo_app/services/api_exception.dart';
import 'package:echo_app/services/api_service.dart';
import 'package:echo_app/services/chat_controller.dart';
import 'package:echo_app/services/voice_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeChatApi api;
  late _FakeVoiceInput voice;
  late ChatController controller;

  setUp(() {
    api = _FakeChatApi();
    voice = _FakeVoiceInput();
    var requestIds = 0;
    controller = ChatController(
      api: api,
      voiceInput: voice,
      clock: () => DateTime.parse('2026-10-02T12:00:00Z'),
      requestIdFactory: () => 'req-${++requestIds}',
    );
  });

  tearDown(() => controller.dispose());

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

  test('409 "Still working on it" shows a friendly message and no retry runs',
      () async {
    api.queryHandler = (_, __) => Future.error(const ApiException(
          statusCode: 409,
          code: 'conflict',
          message: 'Still working on it',
          retryable: false,
        ));

    await controller.send('Email Ann');

    expect(api.queries, ['Email Ann']);
    expect(
      controller.state.error,
      'Echo is still working on your last request.',
    );
    expect(controller.state.messages.single.failed, isTrue);
    expect(controller.state.sending, isFalse);
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

  test('feedback copies the assistant message and awaits the API', () async {
    api.queryHandler = (_, __) async => _response(answer: 'Answer');
    final feedback = Completer<void>();
    api.feedbackHandler = () => feedback.future;
    await controller.send('Question');
    final before = controller.state.messages.last;

    final sendingFeedback = controller.sendFeedback(1, 'positive');

    expect(controller.state.messages.last, isNot(same(before)));
    expect(controller.state.messages.last.feedback, 'positive');
    feedback.complete();
    await sendingFeedback;
    expect(api.feedback.single.chunkIds, isEmpty);
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
  final deletes = <String>[];
  final details = <String, ChatSessionDetail>{};
  final feedback = <_FeedbackCall>[];

  Future<QueryResponse> Function(String question, String? sessionId)?
      queryHandler;
  Future<ChatSessionDetail> Function(String id)? detailHandler;
  Future<void> Function()? feedbackHandler;

  @override
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
  }) {
    queries.add(question);
    querySessionIds.add(sessionId);
    queryRequestIds.add(clientRequestId);
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

  @override
  Future<void> sendFeedback({
    required String sessionId,
    required int messageIndex,
    required String rating,
    List<String> chunkIds = const [],
  }) async {
    feedback.add(_FeedbackCall(sessionId, messageIndex, rating, chunkIds));
    await feedbackHandler?.call();
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

final class _FeedbackCall {
  const _FeedbackCall(
    this.sessionId,
    this.messageIndex,
    this.rating,
    this.chunkIds,
  );

  final String sessionId;
  final int messageIndex;
  final String rating;
  final List<String> chunkIds;
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

  @override
  Future<void> start({
    required void Function(String) onPartial,
    required void Function(String) onFinal,
  }) async {
    _onPartial = onPartial;
    _onFinal = onFinal;
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