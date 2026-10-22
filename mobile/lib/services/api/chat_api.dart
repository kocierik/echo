import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/action_models.dart';
import '../../models/chat_session.dart';
import 'api_client.dart';

class QueryResponse {
  final String answer;
  final String sessionId;
  final List<Map<String, dynamic>> sources;
  final Map<String, dynamic>? dateFilter;
  final PendingAction? pendingAction;

  /// Pages a web search found and the answer cites: {"title", "url"}.
  final List<Map<String, dynamic>> webSources;

  QueryResponse({
    required this.answer,
    required this.sessionId,
    required this.sources,
    this.dateFilter,
    this.pendingAction,
    this.webSources = const [],
  });

  factory QueryResponse.fromJson(Map<String, dynamic> json) {
    return QueryResponse(
      answer: json['answer'] ?? '',
      sessionId: json['session_id'] ?? '',
      sources: List<Map<String, dynamic>>.from(json['sources'] ?? []),
      dateFilter: json['date_filter'],
      webSources: List<Map<String, dynamic>>.from(json['web_sources'] ?? []),
      pendingAction: json['pending_action'] == null
          ? null
          : PendingAction.fromJson(
              json['pending_action'] as Map<String, dynamic>,
            ),
    );
  }
}

abstract interface class ChatApi {
  /// Asks Echo. With [onToken], a memory answer is passed on piece by piece while it
  /// is written; the returned response always holds the whole answer.
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
    void Function(String piece)? onToken,
  });
  Future<List<ChatSessionSummary>> getSessions();
  Future<ChatSessionDetail> getSessionDetail(String id);
  Future<void> deleteSession(String id);
  Future<ConfirmResult> confirmPendingAction(String id);
  Future<void> cancelPendingAction(String id);
}

/// The thread with Echo: what Ask opens (voice, photo, typed and routine messages).
abstract interface class ThreadApi {
  Future<ChatSessionDetail> getThread();
}

/// Ask: questions and chat history. Confirming an action is in
/// actions_api.dart.
mixin ChatEndpoints on ApiClient implements ChatApi, ThreadApi {
  /// `GET /api/chat-sessions/thread`, created on first use; never from the cache: it
  /// changes while the app is closed.
  @override
  Future<ChatSessionDetail> getThread() async {
    final response = await get('/api/chat-sessions/thread');
    return parse(
      response.data,
      (data) => ChatSessionDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
    void Function(String piece)? onToken,
  }) async {
    final body = <String, dynamic>{'question': question, 'top_k': 5};
    if (sessionId != null) body['session_id'] = sessionId;
    if (clientRequestId != null) body['client_request_id'] = clientRequestId;
    if (onToken != null) {
      return _queryStream(
        await url('/api/query/stream'),
        await credentials.headers,
        jsonEncode(body),
        onToken,
      );
    }
    final response = await post('/api/query', body: body, timeout: queryTimeout);
    return parse(
      response.data,
      (data) => QueryResponse.fromJson(data as Map<String, dynamic>),
    );
  }

  /// `POST /api/query/stream`: Server-Sent Events, `token` pieces then `done`.
  Future<QueryResponse> _queryStream(
    Uri uri,
    Map<String, String> headers,
    String body,
    void Function(String piece) onToken,
  ) async {
    final request = http.Request('POST', uri)
      ..headers.addAll(headers)
      ..headers['Accept'] = 'text/event-stream'
      ..body = body;
    final answer = await guard(() async {
      final response = await httpClient.send(request).timeout(requestTimeout);
      if (response.statusCode != 200) {
        if (response.statusCode == 401) await reportUnauthorized(headers['X-API-Key']);
        throw statusException(
          response.statusCode,
          await response.stream.bytesToString(),
        );
      }
      String? event;
      final data = StringBuffer();
      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          // No new line for this long: the answer stalled
          .timeout(queryTimeout);
      await for (final line in lines) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data.write(line.substring(5).trimLeft());
        } else if (line.isEmpty && event != null) {
          final payload = decodeJson(data.toString(), shape: JsonShape.map)
              as Map<String, dynamic>;
          final kind = event;
          event = null;
          data.clear();
          switch (kind) {
            case 'token':
              if (payload['text'] case final String piece) onToken(piece);
            case 'done':
              return parse(
                payload,
                (data) => QueryResponse.fromJson(data as Map<String, dynamic>),
              );
            case 'error':
              throw statusException(
                (payload['status'] as num?)?.toInt() ?? 500,
                jsonEncode({'detail': payload['detail']}),
              );
          }
        }
      }
      return null;
    });
    return answer ??
        (throw offlineException('the answer stopped before it was complete'));
  }

  @override
  Future<List<ChatSessionSummary>> getSessions() async {
    final response = await getCached('/api/chat-sessions');
    return parse(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      return items
          .map((item) => ChatSessionSummary.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<ChatSessionDetail> getSessionDetail(String id) async {
    final response = await getCached('/api/chat-sessions/$id');
    return parse(
      response.data,
      (data) => ChatSessionDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> deleteSession(String id) => delete('/api/chat-sessions/$id');
}
