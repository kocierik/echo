import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/action_models.dart';
import '../models/chat_session.dart';
import '../models/segment.dart';
import '../models/today_insights.dart';
import 'api_exception.dart';
import 'transcript_controller.dart';

class QueryResponse {
  final String answer;
  final String sessionId;
  final List<Map<String, dynamic>> sources;
  final Map<String, dynamic>? dateFilter;
  final PendingAction? pendingAction;

  QueryResponse({
    required this.answer,
    required this.sessionId,
    required this.sources,
    this.dateFilter,
    this.pendingAction,
  });

  factory QueryResponse.fromJson(Map<String, dynamic> json) {
    return QueryResponse(
      answer: json['answer'] ?? '',
      sessionId: json['session_id'] ?? '',
      sources: List<Map<String, dynamic>>.from(json['sources'] ?? []),
      dateFilter: json['date_filter'],
      pendingAction: json['pending_action'] == null
          ? null
          : PendingAction.fromJson(
              json['pending_action'] as Map<String, dynamic>,
            ),
    );
  }
}

abstract interface class ChatApi {
  Future<QueryResponse> query(String question, {String? sessionId});
  Future<List<ChatSessionSummary>> getSessions();
  Future<ChatSessionDetail> getSessionDetail(String id);
  Future<void> deleteSession(String id);
  Future<void> sendFeedback({
    required String sessionId,
    required int messageIndex,
    required String rating,
    List<String> chunkIds = const [],
  });
  Future<ConfirmResult> confirmPendingAction(String id);
  Future<void> cancelPendingAction(String id);
}

abstract interface class TranscriptMemoryApi {
  Future<TranscriptionCorrectionResult> correctTranscription(
    String segmentId,
    String text,
    String speaker,
  );
  Future<void> deleteConversation(String conversationId);
}

abstract interface class ApiCredentialStore {
  Future<bool> get configured;
  Future<String> get serverUrl;
  Future<Map<String, String>> get headers;
  Future<void> configure(String serverUrl, String apiKey);
  Future<void> clear();
}

final class SharedPreferencesApiCredentialStore implements ApiCredentialStore {
  SharedPreferencesApiCredentialStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<SharedPreferences> Function()? preferences,
  })  : _secureStorage = secureStorage,
        _preferences = preferences ?? SharedPreferences.getInstance;

  static const serverKey = 'echo_server_url';
  static const apiKeyKey = 'echo_api_key';

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<bool> get configured async {
    final preferences = await _preferences();
    final server = preferences.getString(serverKey);
    final key = await _readApiKey(preferences);
    return server != null &&
        server.isNotEmpty &&
        key != null &&
        key.isNotEmpty;
  }

  @override
  Future<String> get serverUrl async {
    final preferences = await _preferences();
    return preferences.getString(serverKey) ?? '';
  }

  @override
  Future<Map<String, String>> get headers async {
    final preferences = await _preferences();
    final key = await _readApiKey(preferences);
    return {
      'X-API-Key': key ?? '',
      'Content-Type': 'application/json',
    };
  }

  @override
  Future<void> configure(String serverUrl, String apiKey) async {
    final preferences = await _preferences();
    final normalizedServer =
        serverUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final normalizedKey = apiKey.trim();
    await preferences.setString(serverKey, normalizedServer);
    try {
      await _secureStorage.write(key: apiKeyKey, value: normalizedKey);
    } catch (_) {
      await preferences.setString(apiKeyKey, normalizedKey);
      return;
    }
    await preferences.remove(apiKeyKey);
  }

  @override
  Future<void> clear() async {
    Object? firstError;
    try {
      await _secureStorage.delete(key: apiKeyKey);
    } catch (error) {
      firstError = error;
    }

    try {
      final preferences = await _preferences();
      try {
        await preferences.remove(apiKeyKey);
      } catch (error) {
        firstError ??= error;
      }
      try {
        await preferences.remove(serverKey);
      } catch (error) {
        firstError ??= error;
      }
    } catch (error) {
      firstError ??= error;
    }

    if (firstError != null) {
      throw StateError('Failed to clear API credentials: $firstError');
    }
  }

  Future<String?> _readApiKey(SharedPreferences preferences) async {
    try {
      final key = await _secureStorage.read(key: apiKeyKey);
      if (key != null && key.isNotEmpty) return key;
    } catch (_) {}
    return preferences.getString(apiKeyKey);
  }
}

class ApiService implements ChatApi, TranscriptApi, TranscriptMemoryApi {
  ApiService({
    http.Client? client,
    ApiCredentialStore? credentialStore,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration uploadTimeout = const Duration(seconds: 20),
  })  : _client = client ?? http.Client(),
        _credentialStore =
            credentialStore ?? SharedPreferencesApiCredentialStore(),
        _requestTimeout = requestTimeout,
        _uploadTimeout = uploadTimeout,
        _ownsClient = client == null;

  final http.Client _client;
  final ApiCredentialStore _credentialStore;
  final Duration _requestTimeout;
  final Duration _uploadTimeout;
  final bool _ownsClient;

  Future<bool> isConfigured() => _credentialStore.configured;

  Future<void> configure(String serverUrl, String apiKey) =>
      _credentialStore.configure(serverUrl, apiKey);

  Future<void> clearConfiguration() => _credentialStore.clear();

  Future<String> getServerUrl() => _credentialStore.serverUrl;

  Future<bool> validateCredentials(String serverUrl, String apiKey) async {
    final normalizedServer =
        serverUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final response = await _send(
      () => _client.get(
        Uri.parse('$normalizedServer/api/conversations?limit=1'),
        headers: {'X-API-Key': apiKey.trim()},
      ),
      expectedStatuses: const {200, 401, 403},
      decodeJson: false,
    );
    return response.statusCode == 200;
  }

  @override
  Future<QueryResponse> query(String question, {String? sessionId}) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final body = <String, dynamic>{'question': question, 'top_k': 5};
    if (sessionId != null) body['session_id'] = sessionId;

    final response = await _send(
      () => _client.post(
        Uri.parse('$server/api/query'),
        headers: headers,
        body: jsonEncode(body),
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(
      response.data,
      (data) => QueryResponse.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<List<ChatSessionSummary>> getSessions() async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/chat-sessions'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      return items
          .map((item) => ChatSessionSummary.fromJson(
                item as Map<String, dynamic>,
              ))
          .toList();
    });
  }

  @override
  Future<ChatSessionDetail> getSessionDetail(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/chat-sessions/$id'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(
      response.data,
      (data) => ChatSessionDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> deleteSession(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.delete(
        Uri.parse('$server/api/chat-sessions/$id'),
        headers: headers,
      ),
      expectedStatuses: const {204},
      decodeJson: false,
    );
  }

  @override
  Future<void> sendFeedback({
    required String sessionId,
    required int messageIndex,
    required String rating,
    List<String> chunkIds = const [],
  }) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.post(
        Uri.parse('$server/api/query/feedback'),
        headers: headers,
        body: jsonEncode({
          'session_id': sessionId,
          'message_index': messageIndex,
          'rating': rating,
          'source_chunk_ids': chunkIds,
        }),
      ),
      expectedStatuses: const {201},
      expectedShape: _JsonShape.map,
    );
  }

  Future<bool> testConnection() async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/conversations?limit=1'),
        headers: headers,
      ),
      expectedStatuses: const {200, 401, 403},
      decodeJson: false,
    );
    return response.statusCode == 200;
  }

  Future<List<Conversation>> getConversations() async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/conversations?limit=50'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(response.data, (data) {
      final items =
          (data as Map<String, dynamic>)['conversations'] as List<dynamic>;
      return items
          .map((item) => Conversation.fromJson(
                item as Map<String, dynamic>,
              ))
          .toList();
    });
  }

  @override
  Future<List<RecentSegment>> getRecentSegments({int limit = 50}) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/segments/recent?limit=$limit'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.list,
    );
    return _parseDecoded(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) => RecentSegment.fromJson(
                item as Map<String, dynamic>,
              ))
          .toList();
    });
  }

  @override
  Future<TranscriptionCorrectionResult> correctTranscription(
    String segmentId,
    String text,
    String speaker,
  ) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.patch(
        Uri.parse('$server/api/segments/$segmentId/transcription'),
        headers: headers,
        body: jsonEncode({
          'text': text.trim(),
          'speaker': speaker,
        }),
      ),
      expectedStatuses: const {200, 202},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(
      response.data,
      (data) => TranscriptionCorrectionResult.fromJson(
        data as Map<String, dynamic>,
      ),
    );
  }

  Future<ConversationDetail?> getConversationDetail(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/conversations/$id'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(
      response.data,
      (data) => ConversationDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> deleteConversation(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.delete(
        Uri.parse('$server/api/conversations/$id'),
        headers: headers,
      ),
      expectedStatuses: const {204},
      decodeJson: false,
    );
  }

  Future<Map<String, dynamic>?> getStats() async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(Uri.parse('$server/api/stats'), headers: headers),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> getDigest(String date) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/digest/$date'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getTasks({bool? done}) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    var url = '$server/api/entities?entity_type=task&limit=8';
    if (done != null) url += '&done=$done';
    final response = await _send(
      () => _client.get(Uri.parse(url), headers: headers),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(response.data, (data) {
      final rawTasks =
          (data as Map<String, dynamic>)['entities'] as List<dynamic>;
      final tasks = rawTasks
          .map((item) => item as Map<String, dynamic>)
          .toList();
      final cutoff = DateTime.now().subtract(const Duration(days: 3));
      return tasks.where((task) {
        final metadata = task['metadata_'];
        final isDone =
            metadata is Map<String, dynamic> && metadata['done'] == true;
        if (isDone) return false;
        final createdAt = task['created_at'];
        if (createdAt != null && createdAt is! String) {
          throw const FormatException('created_at must be a string');
        }
        final created = DateTime.tryParse(createdAt as String? ?? '');
        return created == null || created.isAfter(cutoff);
      }).toList();
    });
  }

  /// Open (not done) recent tasks for Today.
  Future<List<OpenTask>> getOpenTasks() async {
    final tasks = await getTasks();
    return tasks
        .map(OpenTask.fromJson)
        .where((task) => task.name.isNotEmpty)
        .toList();
  }

  /// Mark a task done, keeping the rest of its metadata.
  Future<void> completeTask(OpenTask task) {
    return updateEntity(task.id, metadata: task.completedMetadata);
  }

  /// The most recent daily digest of the last two days, or null if none exists.
  Future<DailySummary?> getLatestDigest() async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/digest?days=2'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      final summaries = items
          .map((item) => DailySummary.fromJson(item as Map<String, dynamic>))
          .where((digest) => digest.summary.isNotEmpty)
          .toList();
      return summaries.isEmpty ? null : summaries.first;
    });
  }

  Future<void> updateEntity(
    String id, {
    String? name,
    String? content,
    Map<String, dynamic>? metadata,
  }) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (content != null) body['content'] = content;
    if (metadata != null) body['metadata_'] = metadata;
    await _send(
      () => _client.patch(
        Uri.parse('$server/api/entities/$id'),
        headers: headers,
        body: jsonEncode(body),
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
  }

  /// Upload an audio segment to the backend (used by BLE relay)
  Future<bool> uploadSegment({
    required List<int> audioData,
    required String recordedAt,
    required int durationMs,
    int? silenceBeforeMs,
    int? audioEnergy,
  }) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;

    final uri = Uri.parse('$server/api/segments');
    debugPrint(
      '[API] uploadSegment start uri=$uri recordedAt=$recordedAt '
      'durationMs=$durationMs audioBytes=${audioData.length}',
    );
    final request = http.MultipartRequest('POST', uri);
    request.headers['X-API-Key'] = headers['X-API-Key'] ?? '';
    request.headers['X-Recorded-At'] = recordedAt;
    request.headers['X-Duration-Ms'] = durationMs.toString();
    if (silenceBeforeMs != null) {
      request.headers['X-Silence-Before-Ms'] = silenceBeforeMs.toString();
    }
    if (audioEnergy != null) {
      request.headers['X-Audio-Energy'] = audioEnergy.toString();
    }

    request.files.add(
      http.MultipartFile.fromBytes(
        'audio',
        audioData,
        filename: 'segment.adpcm',
      ),
    );

    _UploadResponse response;
    try {
      response = await (() async {
        final streamedResponse = await _client.send(request);
        final body = await streamedResponse.stream.bytesToString();
        return _UploadResponse(streamedResponse.statusCode, body);
      })().timeout(_uploadTimeout);
    } on TimeoutException {
      throw _timeoutException();
    } on http.ClientException catch (error) {
      throw _offlineException(error);
    } on IOException catch (error) {
      throw _offlineException(error);
    }

    debugPrint(
      '[API] uploadSegment response status=${response.statusCode}',
    );
    if (response.statusCode != 201) {
      throw _statusException(response.statusCode, response.body);
    }
    return true;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }

  // --- Composio actions ---

  Future<List<Toolkit>> getToolkits({String? query}) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final uri = Uri.parse('$server/api/actions/toolkits').replace(
      queryParameters:
          (query == null || query.isEmpty) ? null : {'query': query},
    );
    final response = await _send(
      () => _client.get(uri, headers: headers),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.list,
    );
    return _parseDecoded(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) => Toolkit.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  Future<String> connectToolkit(String slug) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.post(
        Uri.parse('$server/api/actions/toolkits/$slug/connect'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(response.data, (data) {
      final url = (data as Map<String, dynamic>)['url'];
      if (url is! String || url.isEmpty) {
        throw const FormatException('url is missing');
      }
      return url;
    });
  }

  Future<void> disconnectToolkit(String slug) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.delete(
        Uri.parse('$server/api/actions/toolkits/$slug'),
        headers: headers,
      ),
      expectedStatuses: const {204},
      decodeJson: false,
    );
  }

  /// Confirms a pending action and returns the server's status and message.
  @override
  Future<ConfirmResult> confirmPendingAction(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.post(
        Uri.parse('$server/api/actions/pending/$id/confirm'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(response.data, (data) {
      return ConfirmResult.fromJson(data as Map<String, dynamic>);
    });
  }

  @override
  Future<void> cancelPendingAction(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.post(
        Uri.parse('$server/api/actions/pending/$id/cancel'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
  }

  Future<List<ActionLogEntry>> getActionLog({int limit = 50}) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/actions/log?limit=$limit'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.list,
    );
    return _parseDecoded(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) =>
              ActionLogEntry.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  Future<VoiceUpdates> getVoiceUpdates(DateTime? since) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final uri = Uri.parse('$server/api/actions/voice-updates').replace(
      queryParameters:
          since == null ? null : {'since': since.toUtc().toIso8601String()},
    );
    final response = await _send(
      () => _client.get(uri, headers: headers),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(
      response.data,
      (data) => VoiceUpdates.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<_ApiResponse> _send(
    Future<http.Response> Function() request, {
    required Set<int> expectedStatuses,
    bool decodeJson = true,
    _JsonShape expectedShape = _JsonShape.any,
  }) async {
    late final http.Response response;
    try {
      response = await request().timeout(_requestTimeout);
    } on TimeoutException {
      throw _timeoutException();
    } on http.ClientException catch (error) {
      throw _offlineException(error);
    } on IOException catch (error) {
      throw _offlineException(error);
    }

    if (!expectedStatuses.contains(response.statusCode)) {
      throw _statusException(response.statusCode, response.body);
    }

    final data = decodeJson
        ? _decodeJson(response.body, expectedShape: expectedShape)
        : null;
    return _ApiResponse(response.statusCode, data);
  }

  Object? _decodeJson(
    String body, {
    required _JsonShape expectedShape,
  }) {
    late final Object? data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      throw _invalidResponseException();
    }

    if (expectedShape == _JsonShape.map && data is! Map<String, dynamic>) {
      throw _invalidResponseException();
    }
    if (expectedShape == _JsonShape.list && data is! List<dynamic>) {
      throw _invalidResponseException();
    }
    return data;
  }

  T _parseDecoded<T>(Object? data, T Function(Object? data) parse) {
    try {
      return parse(data);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw _invalidResponseException();
    }
  }

  ApiException _statusException(int statusCode, String body) {
    final detail = _extractDetail(body);
    final message = detail ?? 'Request failed with HTTP $statusCode.';
    return switch (statusCode) {
      401 => ApiException(
          statusCode: statusCode,
          code: 'unauthorized',
          message: message,
          retryable: false,
        ),
      403 => ApiException(
          statusCode: statusCode,
          code: 'forbidden',
          message: message,
          retryable: false,
        ),
      404 => ApiException(
          statusCode: statusCode,
          code: 'not_found',
          message: message,
          retryable: false,
        ),
      409 => ApiException(
          statusCode: statusCode,
          code: 'conflict',
          message: message,
          retryable: false,
        ),
      410 => ApiException(
          statusCode: statusCode,
          code: 'expired',
          message: message,
          retryable: false,
        ),
      503 => ApiException(
          statusCode: statusCode,
          code: 'unavailable',
          message: message,
          retryable: true,
        ),
      422 => ApiException(
          statusCode: statusCode,
          code: 'validation',
          message: message,
          retryable: false,
        ),
      408 => ApiException(
          statusCode: statusCode,
          code: 'timeout',
          message: message,
          retryable: true,
        ),
      429 => ApiException(
          statusCode: statusCode,
          code: 'rate_limited',
          message: message,
          retryable: true,
        ),
      >= 500 => ApiException(
          statusCode: statusCode,
          code: 'server',
          message: message,
          retryable: true,
        ),
      _ => ApiException(
          statusCode: statusCode,
          code: 'http',
          message: message,
          retryable: false,
        ),
    };
  }

  String? _extractDetail(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        final detail = data['detail'];
        if (detail is String && detail.isNotEmpty) return detail;
      }
    } catch (_) {}
    return null;
  }

  ApiException _timeoutException() => const ApiException(
        statusCode: null,
        code: 'timeout',
        message: 'The request timed out.',
        retryable: true,
      );

  ApiException _offlineException(Object error) => ApiException(
        statusCode: null,
        code: 'offline',
        message: 'The server could not be reached: $error',
        retryable: true,
      );

  ApiException _invalidResponseException() => const ApiException(
        statusCode: null,
        code: 'invalid_response',
        message: 'The server returned an invalid response.',
        retryable: false,
      );
}

enum _JsonShape { any, map, list }

final class _ApiResponse {
  const _ApiResponse(this.statusCode, this.data);

  final int statusCode;
  final Object? data;
}

final class _UploadResponse {
  const _UploadResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}


class Conversation {
  final String id;
  final String title;
  final String? summary;
  final String startedAt;
  final int segmentCount;
  final String analysisStatus;

  Conversation({
    required this.id,
    required this.title,
    this.summary,
    required this.startedAt,
    required this.segmentCount,
    required this.analysisStatus,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      summary: json['summary'],
      startedAt: json['started_at'] ?? '',
      segmentCount: json['segment_count'] ?? 0,
      analysisStatus: json['analysis_status'] ?? 'pending',
    );
  }
}

class EntityItem {
  final String id;
  final String type;
  final String name;
  final String? content;

  EntityItem({required this.id, required this.type, required this.name, this.content});

  factory EntityItem.fromJson(Map<String, dynamic> json) {
    return EntityItem(
      id: json['id'] ?? '',
      type: json['entity_type'] ?? 'note',
      name: json['name'] ?? '',
      content: json['content'],
    );
  }
}

class TranscriptEntry {
  final String text;
  final String recordedAt;

  TranscriptEntry({required this.text, required this.recordedAt});

  factory TranscriptEntry.fromJson(Map<String, dynamic> json) {
    return TranscriptEntry(
      text: json['text'] ?? '',
      recordedAt: json['recorded_at'] ?? '',
    );
  }
}

class ConversationDetail {
  final String id;
  final String title;
  final String summary;
  final List<EntityItem> entities;
  final List<TranscriptEntry> transcriptions;

  ConversationDetail({
    required this.id,
    required this.title,
    required this.summary,
    required this.entities,
    required this.transcriptions,
  });

  factory ConversationDetail.fromJson(Map<String, dynamic> json) {
    return ConversationDetail(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Conversation',
      summary: json['summary'] ?? '',
      entities: (json['entities'] as List? ?? []).map((e) => EntityItem.fromJson(e)).toList(),
      transcriptions: (json['transcriptions'] as List? ?? []).map((e) => TranscriptEntry.fromJson(e)).toList(),
    );
  }
}
