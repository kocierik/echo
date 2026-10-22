import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/chat_session.dart';
import 'package:echo_app/screens/chat_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/chat/chat_controller.dart';
import 'package:echo_app/services/chat/voice_input.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.now();
  final morning = DateTime(now.year, now.month, now.day, 8, 2);

  ChatSessionDetail thread(List<ChatSessionMessage> messages) => ChatSessionDetail(
        id: 'thread',
        title: 'Echo',
        kind: 'voice',
        messages: messages,
        createdAt: morning,
        updatedAt: morning,
      );

  group('ChatController', () {
    late _ThreadApi api;
    late ChatController controller;

    setUp(() {
      api = _ThreadApi();
      controller = ChatController(api: api, voiceInput: _SilentVoice());
    });

    tearDown(() => controller.dispose());

    test('opens the thread and asks typed questions in it', () async {
      api.thread = thread([
        ChatSessionMessage(
            role: 'user', content: 'che tempo fa?', timestamp: morning, source: 'voice'),
        ChatSessionMessage(role: 'assistant', content: 'Sole.', timestamp: morning),
      ]);

      await controller.openThread();
      expect(controller.state.isThread, isTrue);
      expect(controller.state.sessionId, 'thread');
      expect(controller.state.messages.first.byVoice, isTrue);

      await controller.send('e domani?');
      expect(api.querySessionIds, ['thread']);
    });

    test('a new chat is its own, without the thread', () async {
      api.thread = thread(const []);
      await controller.openThread();

      controller.newChat();
      await controller.send('una cosa a parte');

      expect(controller.state.isThread, isFalse);
      expect(api.querySessionIds, [null]);
    });

    test('a legacy thread message without a source was said by voice', () async {
      api.thread = thread(const [
        ChatSessionMessage(role: 'user', content: 'Echo, che ore sono?'),
        ChatSessionMessage(role: 'assistant', content: 'Le 10.'),
      ]);

      await controller.openThread();

      expect(controller.state.messages.first.byVoice, isTrue);
      expect(controller.state.messages.last.byVoice, isFalse);
    });

    test('Translate it asks about the same photo, in the language spoken', () async {
      controller.dispose();
      controller = ChatController(
        api: api,
        voiceInput: _SilentVoice(),
        spokenLanguage: () async => 'it',
      );
      api.thread = thread(const [
        ChatSessionMessage(role: 'assistant', content: 'È un avviso.', photoId: 'p1'),
      ]);
      await controller.openThread();

      await controller.translatePhoto('p1');

      expect(api.photoQuestions, [('p1', 'Traducilo')]);
      expect(controller.state.messages.last.text, 'Notice: the lift is out of order.');
      expect(controller.state.messages.last.aboutPhotoId, 'p1');
      expect(controller.state.sending, isFalse);
    });

    test('after Ask more, the next question is about the photo', () async {
      api.thread = thread(const [
        ChatSessionMessage(role: 'assistant', content: 'È un avviso.', photoId: 'p1'),
      ]);
      await controller.openThread();

      controller.setPhotoContext('p1');
      expect(controller.state.photoContext, 'p1');
      await controller.send('fino a quando?');

      expect(api.photoQuestions, [('p1', 'fino a quando?')]);
      expect(api.querySessionIds, isEmpty);
      expect(controller.state.photoContext, isNull);
    });

    test('Remind me asks Echo in the thread, with the day', () async {
      controller.dispose();
      controller = ChatController(
        api: api,
        voiceInput: _SilentVoice(),
        spokenLanguage: () async => 'en',
      );
      api.thread = thread(const []);
      await controller.openThread();

      await controller.remindFromPhoto(DateTime(2026, 10, 22, 9));

      expect(api.querySessionIds, ['thread']);
      expect(controller.state.messages.first.text, 'Remind me on Thursday 22 October at 9:00');
    });

    test('a refresh reloads the thread only while it is shown and idle', () async {
      api.thread = thread(const []);
      await controller.openThread();
      api.thread = thread(const [
        ChatSessionMessage(role: 'assistant', content: 'Buongiorno.', routineId: 'r1'),
      ]);

      await controller.refreshThread();
      expect(controller.state.messages.single.text, 'Buongiorno.');
      expect(controller.state.messages.single.routineId, 'r1');

      controller.newChat();
      final reads = api.threadReads;
      await controller.refreshThread();
      expect(api.threadReads, reads);
    });
  });

  group('ChatScreen', () {
    late _ThreadApi api;
    late ChatController controller;

    Future<void> pump(
      WidgetTester tester, {
      ValueNotifier<String?>? ask,
      ValueNotifier<int>? updates,
    }) async {
      controller = ChatController(api: api, voiceInput: _SilentVoice());
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChatScreen(controller: controller, askRequest: ask, threadUpdates: updates),
      ));
      await tester.pumpAndSettle();
    }

    setUp(() => api = _ThreadApi());

    testWidgets('opens on the thread: by voice, the day, a routine answer', (tester) async {
      api.thread = thread([
        ChatSessionMessage(
            role: 'user', content: 'Ehi Echo, che tempo fa?', timestamp: morning, source: 'voice'),
        ChatSessionMessage(role: 'assistant', content: 'Sole, 21 gradi.', timestamp: morning),
        ChatSessionMessage(
            role: 'user', content: 'Il meteo ogni mattina', timestamp: morning, routineId: 'r1'),
        ChatSessionMessage(
            role: 'assistant', content: 'Buongiorno: sole.', timestamp: morning, routineId: 'r1'),
      ]);

      await pump(tester);

      expect(find.text('By voice · 08:02'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('ROUTINE'), findsOneWidget);
      expect(find.text('Buongiorno: sole.'), findsOneWidget);
      // The routine's own instruction is not a question the user asked here
      expect(find.text('Il meteo ogni mattina'), findsNothing);
    });

    testWidgets('an Ask request lands in the thread', (tester) async {
      api.thread = thread(const []);
      final ask = ValueNotifier<String?>('What did Ada say?');
      addTearDown(ask.dispose);

      await pump(tester, ask: ask);

      expect(api.querySessionIds, ['thread']);
      expect(ask.value, isNull);
    });

    testWidgets('a thread update reloads it', (tester) async {
      api.thread = thread(const []);
      final updates = ValueNotifier(0);
      addTearDown(updates.dispose);
      await pump(tester, updates: updates);

      api.thread = thread(const [
        ChatSessionMessage(role: 'assistant', content: 'La foto: un ficus.'),
      ]);
      updates.value++;
      await tester.pumpAndSettle();

      expect(find.text('La foto: un ficus.'), findsOneWidget);
    });
  });
}

final class _ThreadApi implements ChatApi, ThreadApi, PhotoFollowUpApi {
  ChatSessionDetail? thread;
  int threadReads = 0;
  final querySessionIds = <String?>[];
  final photoQuestions = <(String, String)>[];

  @override
  Future<String> askAboutPhoto(String photoId, String question) async {
    photoQuestions.add((photoId, question));
    return 'Notice: the lift is out of order.';
  }

  @override
  Future<ChatSessionDetail> getThread() async {
    threadReads++;
    return thread!;
  }

  @override
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
    void Function(String piece)? onToken,
  }) async {
    querySessionIds.add(sessionId);
    return QueryResponse(answer: 'Answer', sessionId: sessionId ?? 'new', sources: const []);
  }

  @override
  Future<ChatSessionDetail> getSessionDetail(String id) async => thread!;

  @override
  Future<List<ChatSessionSummary>> getSessions() async => const [];

  @override
  Future<void> deleteSession(String id) async {}

  @override
  Future<ConfirmResult> confirmPendingAction(String id) async =>
      const ConfirmResult(status: 'executed', message: 'Done.');

  @override
  Future<void> cancelPendingAction(String id) async {}
}

final class _SilentVoice implements VoiceInput {
  @override
  Future<bool> available() async => true;

  @override
  Future<bool> request() async => true;

  @override
  Future<void> start({
    required ValueChanged<String> onPartial,
    required ValueChanged<String> onFinal,
    String? language,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}
