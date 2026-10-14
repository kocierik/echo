import 'dart:async';

import 'package:echo_app/models/action_models.dart';
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
  testWidgets('suggestion sends a useful literal prompt', (tester) async {
    final harness = _Harness();
    await harness.pump(tester);

    expect(find.text('What did I decide today?'), findsOneWidget);
    await tester.tap(find.text('What did I decide today?'));
    await tester.pumpAndSettle();

    expect(harness.api.queries, ['What did I decide today?']);
    expect(find.text('A grounded answer'), findsOneWidget);
  });

  testWidgets('an Ask request sends the question in a new chat', (tester) async {
    final harness = _Harness();
    final ask = ValueNotifier<String?>('What did I talk about with Ada recently?');
    addTearDown(ask.dispose);

    await harness.pump(tester, askRequest: ask);
    await tester.pumpAndSettle();

    expect(harness.api.queries, ['What did I talk about with Ada recently?']);
    expect(ask.value, isNull);
    expect(find.text('A grounded answer'), findsOneWidget);

    ask.value = 'And with Marco?';
    await tester.pumpAndSettle();
    expect(harness.api.queries.last, 'And with Marco?');
    expect(ask.value, isNull);
  });

  testWidgets('the answer shows while Echo writes it', (tester) async {
    final answer = Completer<QueryResponse>();
    final harness = _Harness(queryHandler: (_, __) => answer.future);
    harness.api.streamPieces = ['Marco suggested ', 'the sushi place.'];
    await harness.pump(tester);

    await tester.enterText(find.byType(TextField), 'What did Marco say?');
    await tester.pump();
    await tester.tap(find.byTooltip('Send question'));
    await tester.pump();

    expect(find.byKey(const Key('chat-streaming')), findsOneWidget);
    expect(find.text('Marco suggested the sushi place.'), findsOneWidget);
    expect(find.byKey(const Key('chat-sending')), findsNothing);

    answer.complete(_response(answer: 'Marco suggested the sushi place.'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-streaming')), findsNothing);
    expect(find.text('Marco suggested the sushi place.'), findsOneWidget);
  });

  testWidgets('send shows loading then error and retry recovers',
      (tester) async {
    final pending = Completer<QueryResponse>();
    var attempts = 0;
    final harness = _Harness(
      queryHandler: (_, __) {
        attempts++;
        if (attempts == 1) return pending.future;
        return Future.value(_response(answer: 'Recovered answer'));
      },
    );
    await harness.pump(tester);

    await tester.enterText(find.byType(TextField), 'Find my launch notes');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    expect(find.byKey(const Key('chat-sending')), findsOneWidget);
    expect(find.text('Find my launch notes'), findsOneWidget);

    pending.completeError(Exception('Network unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Network unavailable'), findsOneWidget);
    expect(find.byKey(const Key('retry-chat-send')), findsOneWidget);

    await tester.tap(find.byKey(const Key('retry-chat-send')));
    await tester.pumpAndSettle();
    expect(find.text('Recovered answer'), findsOneWidget);
    expect(
      find.widgetWithText(MessageBubble, 'Find my launch notes'),
      findsOneWidget,
    );
  });

  testWidgets('history navigation loads complete history and deletes active',
      (tester) async {
    final harness = _Harness(
      sessions: [_summary()],
      details: {
        'session-1': _detail(messages: const [
          ChatSessionMessage(role: 'user', content: 'Saved question'),
          ChatSessionMessage(role: 'assistant', content: 'Saved answer'),
        ]),
      },
    );
    await harness.pump(tester);

    await tester.tap(find.byKey(const Key('chat-history')));
    await tester.pumpAndSettle();
    expect(find.text('Planning'), findsOneWidget);
    await tester.tap(find.text('Planning'));
    await tester.pumpAndSettle();
    expect(find.text('Saved question'), findsOneWidget);
    expect(find.text('Saved answer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-session-session-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-session')));
    await tester.pumpAndSettle();

    expect(harness.api.deletes, ['session-1']);
    expect(find.text('No chat history yet.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Saved answer'), findsNothing);
    expect(find.text('What did I decide today?'), findsOneWidget);
  });

  testWidgets('history failure retains rows and can retry loading',
      (tester) async {
    var attempts = 0;
    final harness = _Harness(
      sessionsHandler: () {
        attempts++;
        if (attempts == 1) throw Exception('History unavailable');
        return Future.value([_summary()]);
      },
    );
    await harness.pump(tester);

    await tester.tap(find.byKey(const Key('chat-history')));
    await tester.pumpAndSettle();
    expect(find.text('History unavailable'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry-chat-history-list')));
    await tester.pumpAndSettle();
    expect(find.text('Planning'), findsOneWidget);
  });

  testWidgets('keyboard inset is safe at 320 width and text scale 1.3',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = _Harness();

    await harness.pump(
      tester,
      mediaQuery: const MediaQueryData(
        size: Size(320, 640),
        viewInsets: EdgeInsets.only(bottom: 260),
        textScaler: TextScaler.linear(1.3),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
  });

  testWidgets('long Markdown and real citations render without fabricated links',
      (tester) async {
    final harness = _Harness();
    await harness.pump(tester);
    harness.api.queryHandler = (_, __) async => _response(
          answer: '# Summary\n\n${List.filled(20, '- A detailed memory').join('\n')}',
          sources: const [
            {'chunk_id': 'chunk-1', 'text': 'The original transcript text.'},
          ],
        );

    await tester.enterText(find.byType(TextField), 'Summarize it');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Sources (1)'), findsOneWidget);
    await tester.tap(find.text('Sources (1)'));
    await tester.pumpAndSettle();
    expect(find.text('The original transcript text.'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mic send and history actions remain 44 square', (tester) async {
    final harness = _Harness();
    await harness.pump(tester);

    for (final key in const [
      Key('chat-mic'),
      Key('chat-send'),
      Key('chat-history'),
    ]) {
      expect(tester.getSize(find.byKey(key)), const Size(44, 44));
    }
  });
}

final class _Harness {
  _Harness({
    Future<QueryResponse> Function(String, String?)? queryHandler,
    Future<List<ChatSessionSummary>> Function()? sessionsHandler,
    List<ChatSessionSummary>? sessions,
    Map<String, ChatSessionDetail>? details,
  })  : api = _FakeChatApi(
          queryHandler: queryHandler,
          sessionsHandler: sessionsHandler,
          sessions: sessions,
          details: details,
        ),
        voice = _FakeVoiceInput();

  final _FakeChatApi api;
  final _FakeVoiceInput voice;
  late final ChatController controller = ChatController(
        api: api,
        voiceInput: voice,
      );

  Future<void> pump(
    WidgetTester tester, {
    MediaQueryData? mediaQuery,
    ValueNotifier<String?>? askRequest,
  }) async {
    addTearDown(controller.dispose);
    Widget child = ChatScreen(controller: controller, askRequest: askRequest);
    if (mediaQuery != null) {
      child = MediaQuery(data: mediaQuery, child: child);
    }
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: child,
    ));
    await tester.pump();
  }
}

QueryResponse _response({
  String answer = 'A grounded answer',
  List<Map<String, dynamic>> sources = const [],
}) =>
    QueryResponse(answer: answer, sessionId: 'session-1', sources: sources);

ChatSessionSummary _summary() => ChatSessionSummary(
      id: 'session-1',
      title: 'Planning',
      messageCount: 2,
      createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
      updatedAt: DateTime.parse('2026-10-01T09:31:00Z'),
    );

ChatSessionDetail _detail({
  List<ChatSessionMessage> messages = const [],
}) =>
    ChatSessionDetail(
      id: 'session-1',
      title: 'Planning',
      messages: messages,
      createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
      updatedAt: DateTime.parse('2026-10-01T09:31:00Z'),
    );

final class _FakeChatApi implements ChatApi {
  _FakeChatApi({
    this.queryHandler,
    this.sessionsHandler,
    List<ChatSessionSummary>? sessions,
    Map<String, ChatSessionDetail>? details,
  })  : sessions = sessions ?? [],
        details = details ?? {};

  Future<QueryResponse> Function(String, String?)? queryHandler;
  final Future<List<ChatSessionSummary>> Function()? sessionsHandler;
  List<ChatSessionSummary> sessions;
  final Map<String, ChatSessionDetail> details;
  final List<String> queries = [];
  final List<String> deletes = [];

  /// Pieces passed to onToken before the answer is returned.
  List<String> streamPieces = const [];

  @override
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
    void Function(String piece)? onToken,
  }) {
    streamPieces.forEach(onToken ?? (_) {});
    queries.add(question);
    return queryHandler?.call(question, sessionId) ?? Future.value(_response());
  }

  @override
  Future<List<ChatSessionSummary>> getSessions() {
    return sessionsHandler?.call() ?? Future.value(List.of(sessions));
  }

  @override
  Future<ChatSessionDetail> getSessionDetail(String id) async => details[id]!;

  @override
  Future<void> deleteSession(String id) async {
    deletes.add(id);
    sessions = sessions.where((session) => session.id != id).toList();
  }

  @override
  Future<void> sendFeedback({
    required String sessionId,
    required int messageIndex,
    required String rating,
    List<String> chunkIds = const [],
  }) async {}

  @override
  Future<ConfirmResult> confirmPendingAction(String id) async =>
      const ConfirmResult(status: 'executed', message: 'Done.');

  @override
  Future<void> cancelPendingAction(String id) async {}
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