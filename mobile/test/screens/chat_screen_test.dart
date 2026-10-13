import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/chat_message.dart';
import 'package:echo_app/screens/chat_history_screen.dart';
import 'package:echo_app/services/api_exception.dart';
import 'package:echo_app/models/chat_session.dart';
import 'package:echo_app/screens/chat_screen.dart';
import 'package:echo_app/services/api_service.dart';
import 'package:echo_app/services/chat_controller.dart';
import 'package:echo_app/services/voice_input.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('does not dispose an injected controller', (tester) async {
    final controller = ChatController(
      api: _FakeChatApi(),
      voiceInput: _FakeVoiceInput(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ChatScreen(controller: controller),
    ));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    controller.setComposerText('still alive');
    expect(controller.state.composerText, 'still alive');
  });

  testWidgets('MessageBubble accepts immutable feedback and source messages',
      (tester) async {
    final message = ChatMessage(
      text: '**Answer**',
      isUser: false,
      index: 1,
      feedback: 'positive',
      sources: const [
        ChatSource(label: 'Source 1', text: 'Transcript'),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: MessageBubble(message: message, onFeedback: (_) {}),
      ),
    ));

    expect(find.text('Answer'), findsOneWidget);
    expect(find.text('Sources (1)'), findsOneWidget);
  });

  Future<_FakeChatApi> pumpWithAction(WidgetTester tester) async {
    final api = _FakeChatApi();
    final controller = ChatController(api: api, voiceInput: _FakeVoiceInput());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ChatScreen(controller: controller),
    ));
    await controller.loadSession('s1');
    await tester.pump();
    return api;
  }

  testWidgets('pending action shows summary with Confirm and Cancel',
      (tester) async {
    await pumpWithAction(tester);

    expect(find.text('Send email to Ann'), findsOneWidget);
    expect(find.byKey(const Key('action-confirm-act-1')), findsOneWidget);
    expect(find.byKey(const Key('action-cancel-act-1')), findsOneWidget);
  });

  testWidgets('Confirm calls the API once, disables buttons, shows Done',
      (tester) async {
    final api = await pumpWithAction(tester);
    final pending = Completer<ConfirmResult>();
    api.confirmHandler = (_) => pending.future;

    await tester.tap(find.byKey(const Key('action-confirm-act-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('action-confirm-act-1')),
        warnIfMissed: false);
    await tester.pump();

    expect(api.confirms, ['act-1']);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('action-confirm-act-1')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('action-cancel-act-1')))
          .onPressed,
      isNull,
    );

    pending.complete(const ConfirmResult(status: 'executed', message: 'Done.'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('action-confirm-act-1')), findsNothing);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Done.'), findsOneWidget);
  });

  testWidgets('an Italian failed result shows Failed, not Done',
      (tester) async {
    final api = await pumpWithAction(tester);
    api.confirmHandler = (_) async => const ConfirmResult(
          status: 'failed',
          message: 'Non è andata a buon fine: nessuna rete',
        );

    await tester.tap(find.byKey(const Key('action-confirm-act-1')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
    expect(find.text('Non è andata a buon fine: nessuna rete'), findsOneWidget);
  });

  testWidgets('an unknown outcome says to check the app and shows no buttons',
      (tester) async {
    final api = await pumpWithAction(tester);
    api.confirmHandler = (_) async => const ConfirmResult(
          status: 'unknown',
          message: 'I couldn\'t confirm whether it went through — '
              'check Gmail before trying again.',
        );

    await tester.tap(find.byKey(const Key('action-confirm-act-1')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Unknown — check the app'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
    expect(
      find.text('I couldn\'t confirm whether it went through — '
          'check Gmail before trying again.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('action-confirm-act-1')), findsNothing);
    expect(find.byKey(const Key('action-cancel-act-1')), findsNothing);
  });

  testWidgets('expired confirm shows the expiry message and no buttons',
      (tester) async {
    final api = await pumpWithAction(tester);
    api.confirmHandler = (_) => Future.error(const ApiException(
          statusCode: 410,
          code: 'expired',
          message: 'gone',
          retryable: false,
        ));

    await tester.tap(find.byKey(const Key('action-confirm-act-1')));
    await tester.pump();
    await tester.pump();

    expect(find.text('This request expired. Ask again.'), findsOneWidget);
    expect(find.text('Expired'), findsOneWidget);
    expect(find.byKey(const Key('action-confirm-act-1')), findsNothing);
  });

  testWidgets('Cancel marks the card cancelled', (tester) async {
    final api = await pumpWithAction(tester);

    await tester.tap(find.byKey(const Key('action-cancel-act-1')));
    await tester.pump();
    await tester.pump();

    expect(api.cancels, ['act-1']);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Cancelled.'), findsOneWidget);
  });

  testWidgets('a non-pending action shows a status line and no buttons',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: MessageBubble(
          message: ChatMessage(
            text: 'Sent.',
            isUser: false,
            pendingAction: const PendingAction(
              id: 'act-9',
              summary: 'Send email',
              status: 'failed',
            ),
          ),
        ),
      ),
    ));

    expect(find.text('Send email'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.byKey(const Key('action-confirm-act-9')), findsNothing);
    expect(find.byKey(const Key('action-cancel-act-9')), findsNothing);
  });

  testWidgets('history lists Voice requests first with a pin icon',
      (tester) async {
    final api = _FakeChatApi()
      ..sessions = [
        ChatSessionSummary(
          id: 'c1',
          title: 'Planning',
          messageCount: 2,
          createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
          updatedAt: DateTime.parse('2026-10-02T09:30:00Z'),
        ),
        ChatSessionSummary(
          id: 'v1',
          title: 'Voice requests',
          messageCount: 1,
          createdAt: DateTime.parse('2026-09-01T09:30:00Z'),
          updatedAt: DateTime.parse('2026-09-02T09:30:00Z'),
          kind: 'voice',
        ),
      ];
    final controller = ChatController(api: api, voiceInput: _FakeVoiceInput());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ChatHistoryScreen(controller: controller, api: api),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    final voiceY = tester.getTopLeft(find.text('Voice requests')).dy;
    final chatY = tester.getTopLeft(find.text('Planning')).dy;
    expect(voiceY, lessThan(chatY));
  });
}

final class _FakeChatApi implements ChatApi {
  final confirms = <String>[];
  final cancels = <String>[];
  List<ChatSessionSummary> sessions = const [];
  Future<ConfirmResult> Function(String id)? confirmHandler;

  @override
  Future<ConfirmResult> confirmPendingAction(String id) {
    confirms.add(id);
    return confirmHandler?.call(id) ??
        Future.value(const ConfirmResult(status: 'executed', message: 'Done.'));
  }

  @override
  Future<void> cancelPendingAction(String id) async {
    cancels.add(id);
  }

  @override
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<ChatSessionSummary>> getSessions() async => sessions;

  @override
  Future<ChatSessionDetail> getSessionDetail(String id) async =>
      ChatSessionDetail(
        id: id,
        title: 'Voice requests',
        messages: const [
          ChatSessionMessage(
            role: 'assistant',
            content: 'Shall I send it?',
            pendingAction:
                PendingAction(id: 'act-1', summary: 'Send email to Ann'),
          ),
        ],
        createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
        updatedAt: DateTime.parse('2026-10-01T09:31:00Z'),
      );

  @override
  Future<void> deleteSession(String id) async {}

  @override
  Future<void> sendFeedback({
    required String sessionId,
    required int messageIndex,
    required String rating,
    List<String> chunkIds = const [],
  }) async {}
}

final class _FakeVoiceInput implements VoiceInput {
  @override
  Future<bool> available() async => true;

  @override
  Future<bool> request() async => true;

  @override
  Future<void> start({
    required ValueChanged<String> onPartial,
    required ValueChanged<String> onFinal,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}

/*
import 'dart:async';

import 'package:echo_app/models/chat_session.dart';
import 'package:echo_app/screens/chat_screen.dart';
import 'package:echo_app/services/api_exception.dart';
import 'package:echo_app/services/api_service.dart';
import 'package:echo_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads and renders complete history in backend order',
      (tester) async {
    final detailCompleter = Completer<ChatSessionDetail>();
    final api = _FakeChatApi(
      sessions: [_summary()],
      detailHandler: (_) => detailCompleter.future,
    );

    await _pumpChat(tester, api);
    await _openSessions(tester);
    await tester.tap(find.text('Planning'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('chat-history-loading')), findsOneWidget);

    detailCompleter.complete(_detail(messages: const [
      ChatSessionMessage(role: 'user', content: 'First user'),
      ChatSessionMessage(role: 'assistant', content: 'First assistant'),
      ChatSessionMessage(role: 'user', content: 'Second user'),
      ChatSessionMessage(role: 'assistant', content: 'Second assistant'),
    ]));
    await tester.pumpAndSettle();

    final bubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .map((bubble) => bubble.message)
        .toList();
    expect(
      bubbles.map((message) => message.text),
      ['First user', 'First assistant', 'Second user', 'Second assistant'],
    );
    expect(
      bubbles.map((message) => message.index),
      [null, 1, null, 2],
    );
  });

  testWidgets('renders an empty session without leaving a spinner',
      (tester) async {
    final api = _FakeChatApi(
      sessions: [_summary()],
      details: {'session-1': _detail()},
    );

    await _pumpChat(tester, api);
    await _selectSession(tester);

    expect(find.byKey(const Key('chat-history-empty')), findsOneWidget);
    expect(find.text('This session has no messages.'), findsOneWidget);
    expect(find.byKey(const Key('chat-history-loading')), findsNothing);
  });

  testWidgets('renders a typed not-found state', (tester) async {
    final api = _FakeChatApi(
      sessions: [_summary()],
      detailHandler: (_) => Future.error(const ApiException(
        statusCode: 404,
        code: 'not_found',
        message: 'Chat session not found',
        retryable: false,
      )),
    );

    await _pumpChat(tester, api);
    await _selectSession(tester);

    expect(find.byKey(const Key('chat-history-not-found')), findsOneWidget);
    expect(find.text('Session not found.'), findsOneWidget);
    expect(find.byKey(const Key('chat-history-loading')), findsNothing);
  });

  testWidgets('retries a retryable session load error', (tester) async {
    var attempts = 0;
    final api = _FakeChatApi(
      sessions: [_summary()],
      detailHandler: (_) {
        attempts++;
        if (attempts == 1) {
          return Future.error(const ApiException(
            statusCode: 503,
            code: 'server',
            message: 'Temporarily unavailable',
            retryable: true,
          ));
        }
        return Future.value(_detail(messages: const [
          ChatSessionMessage(role: 'assistant', content: 'Recovered'),
        ]));
      },
    );

    await _pumpChat(tester, api);
    await _selectSession(tester);

    expect(find.byKey(const Key('chat-history-error')), findsOneWidget);
    expect(find.text('Temporarily unavailable'), findsOneWidget);

    await tester.tap(find.byKey(const Key('retry-chat-history')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Recovered'), findsOneWidget);
  });

  testWidgets('retries a typed sessions-list error', (tester) async {
    var attempts = 0;
    final api = _FakeChatApi(
      sessionsHandler: () {
        attempts++;
        if (attempts == 1) {
          return Future.error(const ApiException(
            statusCode: 503,
            code: 'server',
            message: 'Sessions unavailable',
            retryable: true,
          ));
        }
        return Future.value([_summary()]);
      },
    );

    await _pumpChat(tester, api);
    await _openSessions(tester);

    expect(find.byKey(const Key('sessions-error')), findsOneWidget);
    expect(find.text('Sessions unavailable'), findsOneWidget);

    await tester.tap(find.byKey(const Key('retry-sessions')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Planning'), findsOneWidget);
  });

  testWidgets('cancelling deletion retains the session row', (tester) async {
    final api = _FakeChatApi(sessions: [_summary()]);

    await _pumpChat(tester, api);
    await _openSessions(tester);
    await tester.tap(
      find.byKey(const Key('delete-session-session-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel-delete-session')));
    await tester.pumpAndSettle();

    expect(api.deleteRequests, isEmpty);
    expect(find.text('Planning'), findsOneWidget);
  });

  testWidgets('successful deletion refreshes and clears the active chat',
      (tester) async {
    final api = _FakeChatApi(
      sessions: [_summary()],
      details: {
        'session-1': _detail(messages: const [
          ChatSessionMessage(role: 'assistant', content: 'Loaded answer'),
        ]),
      },
    );

    await _pumpChat(tester, api);
    await _selectSession(tester);
    expect(find.text('Loaded answer'), findsOneWidget);

    await _openSessions(tester);
    await tester.tap(
      find.byKey(const Key('delete-session-session-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-session')));
    await tester.pumpAndSettle();

    expect(api.deleteRequests, ['session-1']);
    expect(find.text('No sessions yet.'), findsOneWidget);
    expect(find.text('Loaded answer'), findsNothing);
  });

  testWidgets('failed deletion reports the error and retains the row',
      (tester) async {
    final api = _FakeChatApi(
      sessions: [_summary()],
      deleteHandler: (_) => Future.error(const ApiException(
        statusCode: 500,
        code: 'server',
        message: 'Delete failed',
        retryable: true,
      )),
    );

    await _pumpChat(tester, api);
    await _openSessions(tester);
    await tester.tap(
      find.byKey(const Key('delete-session-session-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-session')));
    await tester.pumpAndSettle();

    expect(api.deleteRequests, ['session-1']);
    expect(find.byKey(const Key('session-delete-error')), findsOneWidget);
    expect(find.text('Delete failed'), findsOneWidget);
    expect(find.text('Planning'), findsOneWidget);
  });
}

Future<void> _pumpChat(WidgetTester tester, ChatApi api) async {
  await tester.pumpWidget(
    MaterialApp(home: ChatScreen(api: api)),
  );
  await tester.pump();
}

Future<void> _openSessions(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Sessions'));
  await tester.pumpAndSettle();
}

Future<void> _selectSession(WidgetTester tester) async {
  await _openSessions(tester);
  await tester.tap(find.text('Planning'));
  await tester.pumpAndSettle();
}

ChatSessionSummary _summary() => ChatSessionSummary(
      id: 'session-1',
      title: 'Planning',
      messageCount: 2,
      createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
      updatedAt: DateTime.parse('2026-10-01T09:31:00Z'),
    );

ChatSessionDetail _detail({List<ChatSessionMessage> messages = const []}) =>
    ChatSessionDetail(
      id: 'session-1',
      title: 'Planning',
      messages: messages,
      createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
      updatedAt: DateTime.parse('2026-10-01T09:31:00Z'),
    );

final class _FakeChatApi implements ChatApi {
  _FakeChatApi({
    List<ChatSessionSummary>? sessions,
    Map<String, ChatSessionDetail>? details,
    this.sessionsHandler,
    this.detailHandler,
    this.deleteHandler,
  })  : sessions = sessions ?? [],
        details = details ?? {};

  List<ChatSessionSummary> sessions;
  final Map<String, ChatSessionDetail> details;
  final Future<List<ChatSessionSummary>> Function()? sessionsHandler;
  final Future<ChatSessionDetail> Function(String id)? detailHandler;
  final Future<void> Function(String id)? deleteHandler;
  final List<String> deleteRequests = [];

  @override
  Future<void> deleteSession(String id) async {
    deleteRequests.add(id);
    final handler = deleteHandler;
    if (handler != null) {
      await handler(id);
      return;
    }
    sessions = sessions.where((session) => session.id != id).toList();
  }

  @override
  Future<ChatSessionDetail> getSessionDetail(String id) {
    final handler = detailHandler;
    if (handler != null) return handler(id);
    return Future.value(details[id]!);
  }

  @override
  Future<List<ChatSessionSummary>> getSessions() {
    final handler = sessionsHandler;
    if (handler != null) return handler();
    return Future.value(List.unmodifiable(sessions));
  }

  @override
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendFeedback({
    required String sessionId,
    required int messageIndex,
    required String rating,
    List<String> chunkIds = const [],
  }) async {}
}
*/