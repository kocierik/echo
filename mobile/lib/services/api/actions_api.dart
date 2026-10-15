import '../../models/action_models.dart';
import '../../models/today_insights.dart';
import '../chat/voice_updates_service.dart';
import 'api_client.dart';
import 'memory_api.dart';

/// Voice requests being answered and photos on their way (optional for Today).
abstract interface class VoiceWorkingApi {
  Future<List<WorkingItem>> getVoiceWorking();
}

/// Connected apps (Composio), actions waiting for a Confirm, the action log, and
/// what voice requests are doing.
mixin ActionEndpoints on ApiClient
    implements PendingActionsApi, VoiceUpdatesApi, VoiceWorkingApi {
  Future<List<Toolkit>> getToolkits({String? query}) async {
    final path = Uri(
      path: '/api/actions/toolkits',
      queryParameters: (query == null || query.isEmpty) ? null : {'query': query},
    ).toString();
    final response = await get(path, shape: JsonShape.list);
    return parse(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) => Toolkit.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  Future<String> connectToolkit(String slug) async {
    final response = await post('/api/actions/toolkits/$slug/connect');
    return parse(response.data, (data) {
      final url = (data as Map<String, dynamic>)['url'];
      if (url is! String || url.isEmpty) {
        throw const FormatException('url is missing');
      }
      return url;
    });
  }

  Future<void> disconnectToolkit(String slug) =>
      delete('/api/actions/toolkits/$slug');

  @override
  Future<List<PendingAction>> listPendingActions() async {
    final response = await get('/api/actions/pending', shape: JsonShape.list);
    return parse(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) => PendingAction.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  /// Confirms a pending action and returns the server's status and message.
  @override
  Future<ConfirmResult> confirmPendingAction(String id) async {
    final response = await post('/api/actions/pending/$id/confirm');
    return parse(
      response.data,
      (data) => ConfirmResult.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> cancelPendingAction(String id) async {
    await post('/api/actions/pending/$id/cancel');
  }

  Future<List<ActionLogEntry>> getActionLog({int limit = 50}) async {
    final response =
        await get('/api/actions/log?limit=$limit', shape: JsonShape.list);
    return parse(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) => ActionLogEntry.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<VoiceUpdates> getVoiceUpdates(DateTime? since) async {
    final path = Uri(
      path: '/api/actions/voice-updates',
      queryParameters:
          since == null ? null : {'since': since.toUtc().toIso8601String()},
    ).toString();
    final response = await get(path);
    return parse(
      response.data,
      (data) => VoiceUpdates.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<List<WorkingItem>> getVoiceWorking() async {
    final response = await get('/api/actions/voice-working');
    return parse(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      return items
          .map((i) => WorkingItem.fromJson(i as Map<String, dynamic>))
          .toList();
    });
  }
}
