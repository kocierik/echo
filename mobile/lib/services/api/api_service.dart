import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/action_models.dart';
import '../../models/chat_session.dart';
import '../../models/memory.dart';
import '../../models/person.dart';
import '../../models/photo.dart';
import '../../models/upcoming_notification.dart';
import '../../models/voice.dart';
import '../../models/segment.dart';
import '../../models/task_item.dart';
import '../../models/today_insights.dart';
import 'api_exception.dart';
import 'response_cache.dart';
import '../chat/voice_updates_service.dart';

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
  Future<void> sendFeedback({
    required String sessionId,
    required int messageIndex,
    required String rating,
    List<String> chunkIds = const [],
  });
  Future<ConfirmResult> confirmPendingAction(String id);
  Future<void> cancelPendingAction(String id);
}

/// What the Memories and Tasks screens read and change.
abstract interface class MemoryApi {
  Future<List<ConversationCard>> listConversations({int limit = 30, int offset = 0});
  Future<ConversationDetail> getConversation(String id);
  Future<MemorySearchResults> search(String query);
  Future<List<TaskItem>> listTasks({required bool done, int limit = 200});
  Future<void> setTaskDone(TaskItem task, bool done);
  Future<void> deleteEntity(String id);
  Future<void> deleteConversation(String conversationId);
  Future<List<PersonSummary>> listPeople();
  Future<PersonDetail> getPerson(String id);
}

/// Everything Today reads and does: the memory, plus the digest and the actions
/// waiting for a Confirm.
abstract interface class TodayApi implements MemoryApi {
  Future<DailySummary?> getLatestDigest();
  Future<List<PendingAction>> listPendingActions();
  Future<ConfirmResult> confirmPendingAction(String id);
  Future<void> cancelPendingAction(String id);
}

/// The few notifications worth scheduling (briefings, promises, evening recap).
abstract interface class NotificationsApi {
  Future<List<UpcomingNotification>> getUpcomingNotifications({
    required bool briefings,
    required bool promises,
    required bool evening,
  });
}

/// Known voices: the user's own (recorded for it) and people named in transcripts.
abstract interface class VoiceApi {
  Future<VoiceProfiles> getVoiceProfiles();

  /// The segments recorded between the two times are the user's voice.
  Future<VoiceEnrollment> enrollOwnVoice(DateTime startedAt, DateTime endedAt);

  Future<void> deleteVoiceProfile(String id);

  /// Whose voice a segment is: the user's, a person of theirs, or a new name. Returns
  /// how many other segments of the conversation were labelled with it.
  Future<int> nameVoice(String segmentId, {bool isSelf, String? personId, String? name});

  /// Not the suggested person.
  Future<void> rejectVoice(String segmentId);
}

/// Voice requests being answered and photos on their way (optional for Today).
abstract interface class VoiceWorkingApi {
  Future<List<WorkingItem>> getVoiceWorking();
}

/// Weekly summaries (optional for a Today api: no section without it).
abstract interface class WeeklySummaryApi {
  /// The latest weekly summary of the last two weeks, or null.
  Future<WeeklySummary?> getLatestWeeklySummary();
}

abstract interface class TranscriptMemoryApi {
  Future<TranscriptionCorrectionResult> correctTranscription(
    String segmentId,
    String text,
    String speaker,
  );
  Future<void> deleteConversation(String conversationId);
}

/// The wearable camera: requests, the wearable's commands, uploads and images.
abstract interface class PhotoApi {
  /// The app's camera button; the question (if any) and the answer go to
  /// [chatSessionId], or to "Voice requests". [fromWearableButton]: taken with the
  /// wearable's own button, so the answer is notified.
  Future<PhotoInfo> requestPhoto({
    String? question,
    String? chatSessionId,
    bool fromWearableButton = false,
  });

  Future<PhotoInfo> getPhoto(String id);

  Future<void> uploadPhoto(String id, List<int> jpeg, DateTime capturedAt);

  /// [reason]: "muted", "not_connected", "no_camera", "capture_failed" or "busy".
  Future<void> reportPhotoFailure(String id, String reason);

  /// Waits up to [wait] for a command (long poll).
  Future<List<DeviceCommand>> getDeviceCommands({Duration wait});

  Future<PhotoImageSource> photoImage(String id);
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

class ApiService
    implements
        ChatApi,
        TodayApi,
        TranscriptMemoryApi,
        VoiceUpdatesApi,
        PhotoApi,
        WeeklySummaryApi,
        VoiceApi,
        NotificationsApi,
        VoiceWorkingApi {
  ApiService({
    http.Client? client,
    ApiCredentialStore? credentialStore,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration uploadTimeout = const Duration(seconds: 20),
    Duration queryTimeout = const Duration(seconds: 90),
    ResponseCache? cache,
    bool cacheOnly = false,
  })  : _client = client ?? http.Client(),
        _cache = cache ?? FileResponseCache.shared,
        _cacheOnly = cacheOnly,
        _credentialStore =
            credentialStore ?? SharedPreferencesApiCredentialStore(),
        _requestTimeout = requestTimeout,
        _uploadTimeout = uploadTimeout,
        _queryTimeout = queryTimeout,
        _ownsClient = client == null;

  final http.Client _client;
  final ApiCredentialStore _credentialStore;
  final Duration _requestTimeout;
  final Duration _uploadTimeout;

  /// Chat queries may run several tool calls on connected apps.
  final Duration _queryTimeout;
  final bool _ownsClient;
  final ResponseCache _cache;

  /// Reads only the phone's copy: for showing a screen before the server answers.
  final bool _cacheOnly;

  /// The same reads, from the phone's copy only (throws when there is none).
  ApiService cacheView() => ApiService(
        client: _client,
        credentialStore: _credentialStore,
        cache: _cache,
        cacheOnly: true,
      );

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
  Future<QueryResponse> query(
    String question, {
    String? sessionId,
    String? clientRequestId,
    void Function(String piece)? onToken,
  }) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final body = <String, dynamic>{'question': question, 'top_k': 5};
    if (sessionId != null) body['session_id'] = sessionId;
    if (clientRequestId != null) body['client_request_id'] = clientRequestId;
    if (onToken != null) {
      return _queryStream(
        Uri.parse('$server/api/query/stream'),
        headers,
        jsonEncode(body),
        onToken,
      );
    }

    final response = await _send(
      () => _client.post(
        Uri.parse('$server/api/query'),
        headers: headers,
        body: jsonEncode(body),
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
      timeout: _queryTimeout,
    );
    return _parseDecoded(
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
    try {
      final response = await _client.send(request).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw _statusException(response.statusCode, await response.stream.bytesToString());
      }
      String? event;
      final data = StringBuffer();
      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          // No new line for this long: the answer stalled
          .timeout(_queryTimeout);
      await for (final line in lines) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data.write(line.substring(5).trimLeft());
        } else if (line.isEmpty && event != null) {
          final payload = _decodeJson(data.toString(), expectedShape: _JsonShape.map)
              as Map<String, dynamic>;
          final kind = event;
          event = null;
          data.clear();
          switch (kind) {
            case 'token':
              if (payload['text'] case final String piece) onToken(piece);
            case 'done':
              return _parseDecoded(payload, (data) => QueryResponse.fromJson(data as Map<String, dynamic>));
            case 'error':
              throw _statusException(
                (payload['status'] as num?)?.toInt() ?? 500,
                jsonEncode({'detail': payload['detail']}),
              );
          }
        }
      }
    } on TimeoutException {
      throw _timeoutException();
    } on http.ClientException catch (error) {
      throw _offlineException(error);
    } on IOException catch (error) {
      throw _offlineException(error);
    }
    throw _offlineException('the answer stopped before it was complete');
  }

  @override
  Future<List<ChatSessionSummary>> getSessions() async {
    final response = await _getJson('/api/chat-sessions');
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
    final response = await _getJson('/api/chat-sessions/$id');
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

  @override
  Future<List<ConversationCard>> listConversations({
    int limit = 30,
    int offset = 0,
  }) async {
    final response = await _getJson('/api/conversations?limit=$limit&offset=$offset');
    return _parseDecoded(response.data, (data) {
      final items = (data as Map<String, dynamic>)['conversations'] as List<dynamic>;
      return items
          .map((item) => ConversationCard.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<ConversationDetail> getConversation(String id) async {
    final response = await _getJson('/api/conversations/${Uri.encodeComponent(id)}');
    return _parseDecoded(
      response.data,
      (data) => ConversationDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<MemorySearchResults> search(String query) async {
    final q = Uri.encodeQueryComponent(query.trim());
    final response = await _getJson('/api/search?q=$q');
    return _parseDecoded(
      response.data,
      (data) => MemorySearchResults.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<List<TaskItem>> listTasks({required bool done, int limit = 200}) async {
    final response = await _getJson('/api/entities/tasks?done=$done&limit=$limit');
    return _parseDecoded(response.data, (data) {
      final items = (data as Map<String, dynamic>)['entities'] as List<dynamic>;
      return items
          .map((item) => TaskItem.fromJson(item as Map<String, dynamic>))
          .where((task) => task.name.isNotEmpty)
          .toList();
    });
  }

  @override
  Future<void> setTaskDone(TaskItem task, bool done) {
    return updateEntity(task.id, metadata: task.metadataWithDone(done));
  }

  @override
  Future<void> deleteEntity(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.delete(
        Uri.parse('$server/api/entities/${Uri.encodeComponent(id)}'),
        headers: headers,
      ),
      expectedStatuses: const {204},
      decodeJson: false,
    );
  }

  @override
  Future<List<PendingAction>> listPendingActions() async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(Uri.parse('$server/api/actions/pending'), headers: headers),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.list,
    );
    return _parseDecoded(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) => PendingAction.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<List<PersonSummary>> listPeople() async {
    final response = await _getCached('/api/people', _JsonShape.list);
    return _parseDecoded(response.data, (data) {
      return (data as List<dynamic>)
          .map((item) => PersonSummary.fromJson(item as Map<String, dynamic>))
          .where((person) => person.name.isNotEmpty)
          .toList();
    });
  }

  @override
  Future<PersonDetail> getPerson(String id) async {
    final response = await _getJson('/api/people/${Uri.encodeComponent(id)}');
    return _parseDecoded(
      response.data,
      (data) => PersonDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  // --- Wearable camera ---

  @override
  Future<PhotoInfo> requestPhoto({
    String? question,
    String? chatSessionId,
    bool fromWearableButton = false,
  }) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final body = <String, dynamic>{if (fromWearableButton) 'source': 'button'};
    final trimmed = question?.trim() ?? '';
    if (trimmed.isNotEmpty) body['question'] = trimmed;
    if (chatSessionId != null) body['chat_session_id'] = chatSessionId;
    final response = await _send(
      () => _client.post(
        Uri.parse('$server/api/photos'),
        headers: headers,
        body: jsonEncode(body),
      ),
      expectedStatuses: const {201},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(
      response.data,
      (data) => PhotoInfo.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<PhotoInfo> getPhoto(String id) async {
    final response = await _getJson('/api/photos/$id');
    return _parseDecoded(
      response.data,
      (data) => PhotoInfo.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> uploadPhoto(String id, List<int> jpeg, DateTime capturedAt) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final request = http.MultipartRequest('PUT', Uri.parse('$server/api/photos/$id/image'))
      ..headers['X-API-Key'] = headers['X-API-Key'] ?? ''
      ..headers['X-Captured-At'] = capturedAt.toUtc().toIso8601String()
      ..files.add(http.MultipartFile.fromBytes('image', jpeg, filename: 'photo.jpg'));
    _UploadResponse response;
    try {
      response = await (() async {
        final streamed = await _client.send(request);
        return _UploadResponse(streamed.statusCode, await streamed.stream.bytesToString());
      })()
          .timeout(_uploadTimeout);
    } on TimeoutException {
      throw _timeoutException();
    } on http.ClientException catch (error) {
      throw _offlineException(error);
    } on IOException catch (error) {
      throw _offlineException(error);
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _statusException(response.statusCode, response.body);
    }
  }

  @override
  Future<void> reportPhotoFailure(String id, String reason) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.post(
        Uri.parse('$server/api/photos/$id/failure'),
        headers: headers,
        body: jsonEncode({'reason': reason}),
      ),
      expectedStatuses: const {200},
      decodeJson: false,
    );
  }

  @override
  Future<List<DeviceCommand>> getDeviceCommands({
    Duration wait = const Duration(seconds: 20),
  }) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(
        Uri.parse('$server/api/device/commands?wait=${wait.inSeconds}'),
        headers: headers,
      ),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
      // The server holds the request open for up to `wait`
      timeout: wait + _requestTimeout,
    );
    return _parseDecoded(response.data, (data) {
      final commands = (data as Map<String, dynamic>)['commands'];
      if (commands is! List<dynamic>) throw const FormatException('commands');
      return commands.map(DeviceCommand.tryParse).whereType<DeviceCommand>().toList();
    });
  }

  @override
  Future<PhotoImageSource> photoImage(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    return PhotoImageSource(
      url: Uri.parse('$server/api/photos/$id/image'),
      headers: {'X-API-Key': headers['X-API-Key'] ?? ''},
    );
  }

  Future<_ApiResponse> _getJson(String path) => _getCached(path, _JsonShape.map);

  /// A read that keeps its answer on the phone, and falls back to it when the server
  /// cannot be reached (then [offlineDataSince] says since when the data is).
  Future<_ApiResponse> _getCached(String path, _JsonShape shape) async {
    final server = await _credentialStore.serverUrl;
    final key = '$server$path';
    if (_cacheOnly) {
      final cached = await _cache.read(key);
      if (cached == null) throw _offlineException('no copy on this phone');
      return _ApiResponse(200, _decodeJson(cached.body, expectedShape: shape));
    }
    final headers = await _credentialStore.headers;
    try {
      final response = await _send(
        () => _client.get(Uri.parse(key), headers: headers),
        expectedStatuses: const {200},
        expectedShape: shape,
      );
      unawaited(_cache.write(key, jsonEncode(response.data)));
      offlineDataSince.value = null;
      return response;
    } on ApiException catch (error) {
      if (error.code != 'offline' && error.code != 'timeout') rethrow;
      final cached = await _cache.read(key);
      if (cached == null) rethrow;
      offlineDataSince.value = cached.savedAt;
      return _ApiResponse(200, _decodeJson(cached.body, expectedShape: shape));
    }
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





  /// The most recent daily digest of the last two days, or null if none exists.
  @override
  Future<DailySummary?> getLatestDigest() async {
    final response = await _getJson('/api/digest?days=2');
    return _parseDecoded(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      final summaries = items
          .map((item) => DailySummary.fromJson(item as Map<String, dynamic>))
          .where((digest) => digest.summary.isNotEmpty)
          .toList();
      return summaries.isEmpty ? null : summaries.first;
    });
  }

  @override
  Future<List<UpcomingNotification>> getUpcomingNotifications({
    required bool briefings,
    required bool promises,
    required bool evening,
  }) async {
    final response = await _getJson(
      '/api/notifications/upcoming?briefings=$briefings&promises=$promises&evening=$evening',
    );
    return _parseDecoded(response.data, (data) {
      final items = (data as Map<String, dynamic>)['notifications'] as List<dynamic>;
      return items
          .map((item) => UpcomingNotification.fromJson(item as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<List<WorkingItem>> getVoiceWorking() async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    final response = await _send(
      () => _client.get(Uri.parse('$server/api/actions/voice-working'), headers: headers),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
    return _parseDecoded(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      return items.map((i) => WorkingItem.fromJson(i as Map<String, dynamic>)).toList();
    });
  }

  /// Everything the server keeps about the user, as the JSON file to save.
  Future<List<int>> exportData() async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    late final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$server/api/export'), headers: headers)
          .timeout(_queryTimeout);
    } on TimeoutException {
      throw _timeoutException();
    } on http.ClientException catch (error) {
      throw _offlineException(error);
    } on IOException catch (error) {
      throw _offlineException(error);
    }
    if (response.statusCode != 200) throw _statusException(response.statusCode, response.body);
    return response.bodyBytes;
  }

  // --- Voices ---

  @override
  Future<VoiceProfiles> getVoiceProfiles() async {
    final response = await _getJson('/api/voice-profiles');
    return _parseDecoded(
      response.data,
      (data) => VoiceProfiles.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<VoiceEnrollment> enrollOwnVoice(DateTime startedAt, DateTime endedAt) async {
    final response = await _postJson('/api/voice-profiles/self/enroll', {
      'started_at': startedAt.toUtc().toIso8601String(),
      'ended_at': endedAt.toUtc().toIso8601String(),
    });
    return _parseDecoded(
      response.data,
      (data) => VoiceEnrollment.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> deleteVoiceProfile(String id) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.delete(Uri.parse('$server/api/voice-profiles/$id'), headers: headers),
      expectedStatuses: const {204},
      decodeJson: false,
    );
  }

  @override
  Future<int> nameVoice(
    String segmentId, {
    bool isSelf = false,
    String? personId,
    String? name,
  }) async {
    final response = await _postJson('/api/segments/$segmentId/voice', {
      'is_self': isSelf,
      if (personId != null) 'person_id': personId,
      if (name != null) 'name': name,
    });
    return _parseDecoded(
      response.data,
      (data) => (data as Map<String, dynamic>)['relabelled'] as int,
    );
  }

  @override
  Future<void> rejectVoice(String segmentId) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    await _send(
      () => _client.post(
        Uri.parse('$server/api/segments/$segmentId/voice/reject'),
        headers: headers,
      ),
      expectedStatuses: const {204},
      decodeJson: false,
    );
  }

  Future<_ApiResponse> _postJson(String path, Map<String, dynamic> body) async {
    final server = await _credentialStore.serverUrl;
    final headers = await _credentialStore.headers;
    return _send(
      () => _client.post(Uri.parse('$server$path'), headers: headers, body: jsonEncode(body)),
      expectedStatuses: const {200},
      expectedShape: _JsonShape.map,
    );
  }

  @override
  Future<WeeklySummary?> getLatestWeeklySummary() async {
    final response = await _getJson('/api/digest/weekly?weeks=2');
    return _parseDecoded(response.data, (data) {
      final items = (data as Map<String, dynamic>)['items'] as List<dynamic>;
      final weeks = items
          .map((item) => WeeklySummary.fromJson(item as Map<String, dynamic>))
          .where((week) => week.summary.isNotEmpty)
          .toList();
      return weeks.isEmpty ? null : weeks.first;
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

  @override
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
    Duration? timeout,
  }) async {
    late final http.Response response;
    try {
      response = await request().timeout(timeout ?? _requestTimeout);
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
