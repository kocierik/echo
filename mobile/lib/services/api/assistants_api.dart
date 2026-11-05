import '../../models/assistant.dart';
import 'api_client.dart';

/// Profile → Assistants: the user's assistants, made from a template or blank, edited,
/// deleted.
abstract interface class AssistantsApi {
  Future<List<Assistant>> listAssistants();
  Future<List<AssistantTemplate>> assistantTemplates();
  Future<Assistant> createAssistant(AssistantDraft draft);
  Future<Assistant> updateAssistant(String id, AssistantDraft draft);

  /// Its chats and routines stay, with plain Echo.
  Future<void> deleteAssistant(String id);

  /// What the user described ([topic]; a [template] key as its start) made into a
  /// proposal, to change and save.
  Future<AssistantDraft> composeAssistant({String? template, String? topic});

  /// ✨ Improve: a few words of instructions made into full ones.
  Future<String> improveInstructions({required String name, required String instructions});
}

mixin AssistantsEndpoints on ApiClient implements AssistantsApi {
  @override
  Future<List<Assistant>> listAssistants() async {
    final response = await get('/api/assistants');
    return parse(response.data, (data) {
      final items = (data as Map<String, dynamic>)['assistants'] as List<dynamic>? ?? const [];
      return [
        for (final item in items)
          if (item is Map<String, dynamic>) Assistant.fromJson(item),
      ];
    });
  }

  @override
  Future<List<AssistantTemplate>> assistantTemplates() async {
    final response = await get('/api/assistants/templates', shape: JsonShape.list);
    return parse(
        response.data,
        (data) => [
              for (final item in data as List<dynamic>)
                if (item is Map<String, dynamic>) AssistantTemplate.fromJson(item),
            ]);
  }

  @override
  Future<Assistant> createAssistant(AssistantDraft draft) async {
    final response = await post('/api/assistants', body: draft.toJson(), expect: const {201});
    return parse(response.data, (data) => Assistant.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<Assistant> updateAssistant(String id, AssistantDraft draft) async {
    final response = await patch('/api/assistants/$id', body: draft.toJson());
    return parse(response.data, (data) => Assistant.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<void> deleteAssistant(String id) => delete('/api/assistants/$id');

  @override
  Future<AssistantDraft> composeAssistant({String? template, String? topic}) async {
    final response = await post(
      '/api/assistants/compose',
      body: {
        if (template != null) 'template': template,
        if (topic != null) 'topic': topic,
      },
      timeout: queryTimeout,
    );
    return parse(
      response.data,
      (data) => AssistantDraft.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<String> improveInstructions({required String name, required String instructions}) async {
    final response = await post(
      '/api/assistants/improve',
      body: {'name': name, 'instructions': instructions},
      timeout: queryTimeout,
    );
    return parse(
      response.data,
      (data) => (data as Map<String, dynamic>)['instructions'] as String,
    );
  }
}
