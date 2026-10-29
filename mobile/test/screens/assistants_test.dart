import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/assistant.dart';
import 'package:echo_app/models/chat_session.dart';
import 'package:echo_app/models/memory_items.dart';
import 'package:echo_app/screens/chat_history_screen.dart';
import 'package:echo_app/screens/chat_screen.dart';
import 'package:echo_app/screens/settings/assistants_screen.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/chat/chat_controller.dart';
import 'package:echo_app/services/chat/voice_input.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _templates = [
  AssistantTemplate(key: 'work', name: 'Lavoro', emoji: '💼', instructions: 'Aiutami col lavoro.'),
  AssistantTemplate(
    key: 'diet',
    name: 'Dieta',
    emoji: '🥗',
    instructions: 'Coach per l’alimentazione. Non sono un medico.',
  ),
  AssistantTemplate(key: 'sleep', name: 'Sonno', emoji: '😴', instructions: 'Coach del sonno.'),
];

const _diet = Assistant(
  id: 'a1',
  name: 'Dieta',
  emoji: '🥗',
  instructions: 'Coach per l’alimentazione.',
  notes: '',
  documentIds: [],
);

final class _Api implements AssistantsApi, DocumentsApi, ChatApi {
  _Api({List<Assistant>? assistants}) : assistants = assistants ?? [];

  List<Assistant> assistants;
  final created = <AssistantDraft>[];
  final updated = <(String, AssistantDraft)>[];
  final deleted = <String>[];
  final assistantIds = <String?>[];
  List<ChatSessionSummary> sessions = [];
  ApiException? refuseCreate;

  /// The assistant asked was deleted elsewhere: the server says it is not found.
  bool assistantGone = false;

  @override
  Future<List<Assistant>> listAssistants() async => assistants;

  @override
  Future<List<AssistantTemplate>> assistantTemplates() async => _templates;

  @override
  Future<Assistant> createAssistant(AssistantDraft draft) async {
    if (refuseCreate != null) throw refuseCreate!;
    created.add(draft);
    final made = Assistant(
      id: 'n${assistants.length}',
      name: draft.name,
      emoji: draft.emoji,
      instructions: draft.instructions,
      notes: draft.notes,
      documentIds: draft.documentIds,
    );
    assistants = [...assistants, made];
    return made;
  }

  @override
  Future<Assistant> updateAssistant(String id, AssistantDraft draft) async {
    updated.add((id, draft));
    final made = Assistant(
      id: id,
      name: draft.name,
      emoji: draft.emoji,
      instructions: draft.instructions,
      notes: draft.notes,
      documentIds: draft.documentIds,
    );
    assistants = [for (final a in assistants) a.id == id ? made : a];
    return made;
  }

  @override
  Future<void> deleteAssistant(String id) async {
    deleted.add(id);
    assistants = assistants.where((a) => a.id != id).toList();
  }

  @override
  Future<List<UserDocument>> listDocuments() async => const [
        UserDocument(
          id: 'd1',
          title: 'Piano.pdf',
          kind: 'pdf',
          sizeBytes: 1,
          status: 'ready',
          wordCount: 100,
        ),
      ];

  @override
  Future<UserDocument> uploadDocument(String filename, List<int> bytes) =>
      throw UnimplementedError();

  @override
  Future<UserDocument> getDocument(String id) => throw UnimplementedError();

  @override
  Future<void> deleteDocument(String id) => throw UnimplementedError();

  @override
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
    String? assistantId,
    void Function(String piece)? onToken,
  }) async {
    assistantIds.add(assistantId);
    if (assistantGone && assistantId != null) {
      throw const ApiException(
        statusCode: 404,
        code: 'not_found',
        message: 'Assistant not found',
        retryable: false,
      );
    }
    return QueryResponse(answer: 'Minestrone.', sessionId: 's1', sources: []);
  }

  @override
  Future<List<ChatSessionSummary>> getSessions() async => sessions;

  @override
  Future<ChatSessionDetail> getSessionDetail(String id) => throw UnimplementedError();

  @override
  Future<void> deleteSession(String id) async {}

  @override
  Future<ConfirmResult> confirmPendingAction(String id) => throw UnimplementedError();

  @override
  Future<void> cancelPendingAction(String id) async {}
}

final class _Voice implements VoiceInput {
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

Future<void> _pumpAssistants(WidgetTester tester, _Api api) async {
  // Tall enough for the whole editor: a list builds only what is on screen
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    home: AssistantsScreen(api: api, documents: api),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('Profile → Assistants', () {
    testWidgets('a new one from a template, saved as it was edited', (tester) async {
      final api = _Api();
      await _pumpAssistants(tester, api);
      expect(find.byKey(const Key('assistants-empty')), findsOneWidget);

      await _tap(tester, find.byKey(const Key('assistants-new')));
      await _tap(tester, find.byKey(const Key('assistant-template-diet')));
      // Prefilled from the template, still editable
      expect(find.text('Dieta'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('assistant-name')), 'Coach');
      await _tap(tester, find.byKey(const Key('assistant-save')));

      expect(api.created.single.name, 'Coach');
      expect(api.created.single.emoji, '🥗');
      expect(api.created.single.instructions, contains('Non sono un medico'));
      expect(find.byKey(const Key('assistant-n0')), findsOneWidget);
      expect(find.text('Coach'), findsOneWidget);
    });

    testWidgets('a blank one needs a name and instructions', (tester) async {
      final api = _Api();
      await _pumpAssistants(tester, api);

      await _tap(tester, find.byKey(const Key('assistants-new')));
      await _tap(tester, find.byKey(const Key('assistant-template-blank')));
      await _tap(tester, find.byKey(const Key('assistant-save')));
      expect(api.created, isEmpty);
      expect(find.text('Give it a name and instructions.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('assistant-name')), 'Viaggi');
      await tester.enterText(
        find.byKey(const Key('assistant-instructions')),
        'Aiutami a organizzare i viaggi.',
      );
      await _tap(tester, find.byKey(const Key('assistant-save')));

      expect(api.created.single.name, 'Viaggi');
    });

    testWidgets('its notes and documents are edited', (tester) async {
      final api = _Api(assistants: [_diet]);
      await _pumpAssistants(tester, api);

      await _tap(tester, find.byKey(const Key('assistant-a1')));
      await tester.enterText(find.byKey(const Key('assistant-notes')), '- Vegetariano');
      await _tap(tester, find.byKey(const Key('assistant-document-d1')));
      await _tap(tester, find.byKey(const Key('assistant-save')));

      final (id, draft) = api.updated.single;
      expect(id, 'a1');
      expect(draft.notes, '- Vegetariano');
      expect(draft.documentIds, ['d1']);
    });

    testWidgets('the documents line says which ones it searches', (tester) async {
      final api = _Api(assistants: [_diet]);
      await _pumpAssistants(tester, api);
      await _tap(tester, find.byKey(const Key('assistant-a1')));
      expect(find.text('None chosen: it searches all of your documents.'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('assistant-document-d1')));

      expect(find.text('None chosen: it searches all of your documents.'), findsNothing);
      expect(find.text('It searches only the ones chosen.'), findsOneWidget);
    });

    testWidgets('deleting one asks first', (tester) async {
      final api = _Api(assistants: [_diet]);
      await _pumpAssistants(tester, api);

      await _tap(tester, find.byKey(const Key('assistant-a1')));
      await _tap(tester, find.byKey(const Key('assistant-delete')));
      expect(api.deleted, isEmpty);
      await _tap(tester, find.widgetWithText(TextButton, 'Delete'));

      expect(api.deleted, ['a1']);
      expect(find.byKey(const Key('assistant-a1')), findsNothing);
    });

    testWidgets('what the server refuses is said', (tester) async {
      final api = _Api()
        ..refuseCreate = const ApiException(
          statusCode: 409,
          code: 'conflict',
          message: 'You can have at most 10 assistants.',
          retryable: false,
        );
      await _pumpAssistants(tester, api);

      await _tap(tester, find.byKey(const Key('assistants-new')));
      await _tap(tester, find.byKey(const Key('assistant-template-work')));
      await _tap(tester, find.byKey(const Key('assistant-save')));

      expect(find.text('You can have at most 10 assistants.'), findsOneWidget);
    });
  });

  group('Ask', () {
    testWidgets('a new chat can start with an assistant', (tester) async {
      final api = _Api(assistants: [
        _diet,
        const Assistant(id: 'a2', name: 'Lavoro', emoji: '💼', instructions: 'x', notes: '',
            documentIds: []),
        const Assistant(id: 'a3', name: 'Sonno', emoji: '😴', instructions: 'x', notes: '',
            documentIds: []),
      ]);
      // A phone's width: three assistants do not fit on one line
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ChatController(api: api, voiceInput: _Voice());
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChatScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask-assistant-echo')), findsOneWidget);
      // One row, scrolling sideways when they do not fit
      expect(
        tester.getTopLeft(find.byKey(const Key('ask-assistant-a3'))).dy,
        tester.getTopLeft(find.byKey(const Key('ask-assistant-echo'))).dy,
      );
      await _tap(tester, find.byKey(const Key('ask-assistant-a1')));
      await tester.enterText(find.byType(TextField), 'cosa mangio stasera?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send question'));
      await tester.pumpAndSettle();

      expect(api.assistantIds, ['a1']);
      // The chat says who it is with; no choosing once it started
      expect(find.byKey(const Key('chat-assistant')), findsOneWidget);
      expect(find.byKey(const Key('ask-assistant-echo')), findsNothing);
    });

    testWidgets('an assistant deleted elsewhere: the question waits, the chips refresh',
        (tester) async {
      final api = _Api(assistants: [_diet]);
      final controller = ChatController(api: api, voiceInput: _Voice());
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChatScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      await _tap(tester, find.byKey(const Key('ask-assistant-a1')));
      api
        ..assistants = []
        ..assistantGone = true;
      await tester.enterText(find.byType(TextField), 'cosa mangio stasera?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send question'));
      await tester.pumpAndSettle();

      // Not lost, not sent to Echo instead: back in the composer, with Echo chosen
      expect(controller.state.messages, isEmpty);
      expect(controller.state.composerText, 'cosa mangio stasera?');
      expect(controller.state.assistant, isNull);
      expect(find.textContaining('no longer exists'), findsOneWidget);
      expect(find.byKey(const Key('ask-assistant-a1')), findsNothing);
    });

    testWidgets('without assistants nothing changes', (tester) async {
      final api = _Api();
      final controller = ChatController(api: api, voiceInput: _Voice());
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChatScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask-assistant-echo')), findsNothing);
    });

    testWidgets('history shows a chat\'s assistant', (tester) async {
      final api = _Api()
        ..sessions = [
          ChatSessionSummary(
            id: 's1',
            title: 'Cena',
            messageCount: 2,
            createdAt: DateTime.parse('2026-10-01T09:30:00Z'),
            updatedAt: DateTime.parse('2026-10-01T09:31:00Z'),
            assistant: const ChatAssistant(id: 'a1', name: 'Dieta', emoji: '🥗'),
          ),
        ];
      final controller = ChatController(api: api, voiceInput: _Voice());
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChatHistoryScreen(controller: controller, api: api),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('session-assistant-s1')), findsOneWidget);
      expect(find.text('Dieta · 2 messages'), findsOneWidget);
    });
  });
}
