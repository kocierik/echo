import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class QueryResponse {
  final String answer;
  final String sessionId;
  final List<Map<String, dynamic>> sources;
  final Map<String, dynamic>? dateFilter;

  QueryResponse({
    required this.answer,
    required this.sessionId,
    required this.sources,
    this.dateFilter,
  });

  factory QueryResponse.fromJson(Map<String, dynamic> json) {
    return QueryResponse(
      answer: json['answer'] ?? '',
      sessionId: json['session_id'] ?? '',
      sources: List<Map<String, dynamic>>.from(json['sources'] ?? []),
      dateFilter: json['date_filter'],
    );
  }
}

class ChatSession {
  final String id;
  final String title;
  final String updatedAt;
  final int messageCount;

  ChatSession({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messageCount,
  });

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Chat',
      updatedAt: json['updated_at'] ?? '',
      messageCount: json['message_count'] ?? 0,
    );
  }
}

class ApiService {
  static const _serverKey = 'echo_server_url';
  static const _apiKeyKey = 'echo_api_key';
  static const _segmentUploadTimeout = Duration(seconds: 20);

  final _secureStorage = const FlutterSecureStorage();

  Future<bool> isConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString(_serverKey);
    String? key;
    try {
      key = await _secureStorage.read(key: _apiKeyKey);
    } catch (_) {
      // Fallback: keyring not available (Linux without gnome-keyring)
      key = prefs.getString(_apiKeyKey);
    }
    return server != null && server.isNotEmpty && key != null && key.isNotEmpty;
  }

  Future<void> configure(String serverUrl, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, serverUrl.trimRight());
    try {
      await _secureStorage.write(key: _apiKeyKey, value: apiKey.trim());
    } catch (_) {
      // Fallback: store in shared_preferences (less secure, but works on Linux)
      await prefs.setString(_apiKeyKey, apiKey.trim());
    }
  }

  Future<String> get _serverUrl async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverKey) ?? '';
  }

  Future<Map<String, String>> get _headers async {
    String? key;
    try {
      key = await _secureStorage.read(key: _apiKeyKey);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      key = prefs.getString(_apiKeyKey);
    }
    return {
      'X-API-Key': key ?? '',
      'Content-Type': 'application/json',
    };
  }

  Future<QueryResponse> query(String question, {String? sessionId}) async {
    final server = await _serverUrl;
    final headers = await _headers;
    final body = <String, dynamic>{'question': question, 'top_k': 5};
    if (sessionId != null) body['session_id'] = sessionId;

    final response = await http.post(
      Uri.parse('$server/api/query'),
      headers: headers,
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception('Query failed: ${response.statusCode} ${response.body}');
    }

    return QueryResponse.fromJson(jsonDecode(response.body));
  }

  Future<List<ChatSession>> getSessions() async {
    final server = await _serverUrl;
    final headers = await _headers;

    final response = await http.get(
      Uri.parse('$server/api/chat-sessions'),
      headers: headers,
    );

    if (response.statusCode != 200) return [];

    final data = jsonDecode(response.body);
    final items = data['items'] as List? ?? [];
    return items.map((e) => ChatSession.fromJson(e)).toList();
  }

  Future<void> deleteSession(String id) async {
    final server = await _serverUrl;
    final headers = await _headers;
    await http.delete(Uri.parse('$server/api/chat-sessions/$id'), headers: headers);
  }

  Future<void> sendFeedback({
    required String sessionId,
    required int messageIndex,
    required String rating,
    List<String> chunkIds = const [],
  }) async {
    final server = await _serverUrl;
    final headers = await _headers;
    await http.post(
      Uri.parse('$server/api/query/feedback'),
      headers: headers,
      body: jsonEncode({
        'session_id': sessionId,
        'message_index': messageIndex,
        'rating': rating,
        'source_chunk_ids': chunkIds,
      }),
    );
  }

  Future<bool> testConnection() async {
    try {
      final server = await _serverUrl;
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$server/health'),
        headers: headers,
      ).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<Conversation>> getConversations() async {
    final server = await _serverUrl;
    final headers = await _headers;

    final response = await http.get(
      Uri.parse('$server/api/conversations?limit=50'),
      headers: headers,
    );

    if (response.statusCode != 200) return [];

    final data = jsonDecode(response.body);
    final items = data['conversations'] as List? ?? [];
    return items.map((e) => Conversation.fromJson(e)).toList();
  }

  Future<ConversationDetail?> getConversationDetail(String id) async {
    final server = await _serverUrl;
    final headers = await _headers;

    final response = await http.get(
      Uri.parse('$server/api/conversations/$id'),
      headers: headers,
    );

    if (response.statusCode != 200) return null;
    return ConversationDetail.fromJson(jsonDecode(response.body));
  }

  Future<Map<String, dynamic>?> getStats() async {
    final server = await _serverUrl;
    final headers = await _headers;
    final response = await http.get(Uri.parse('$server/api/stats'), headers: headers);
    if (response.statusCode != 200) return null;
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>?> getDigest(String date) async {
    final server = await _serverUrl;
    final headers = await _headers;
    final response = await http.get(Uri.parse('$server/api/digest/$date'), headers: headers);
    if (response.statusCode != 200) return null;
    return jsonDecode(response.body);
  }

  Future<List<Map<String, dynamic>>> getTasks({bool? done}) async {
    final server = await _serverUrl;
    final headers = await _headers;
    // Only fetch undone tasks, most recent first, limited
    var url = '$server/api/entities?entity_type=task&limit=8';
    if (done != null) url += '&done=$done';
    final response = await http.get(Uri.parse(url), headers: headers);
    if (response.statusCode != 200) return [];
    final data = jsonDecode(response.body);
    final tasks = List<Map<String, dynamic>>.from(data['entities'] ?? []);
    // Filter: only undone tasks from last 3 days
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    return tasks.where((t) {
      final isDone = t['metadata_']?['done'] == true;
      if (isDone) return false;
      final created = DateTime.tryParse(t['created_at'] ?? '');
      if (created == null) return true;
      return created.isAfter(cutoff);
    }).toList();
  }

  Future<void> updateEntity(String id, {String? name, String? content, Map<String, dynamic>? metadata}) async {
    final server = await _serverUrl;
    final headers = await _headers;
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (content != null) body['content'] = content;
    if (metadata != null) body['metadata_'] = metadata;
    await http.patch(Uri.parse('$server/api/entities/$id'), headers: headers, body: jsonEncode(body));
  }

  // --- Integrations ---

  Future<List<Map<String, dynamic>>> getAvailableProviders() async {
    final server = await _serverUrl;
    final headers = await _headers;
    final response = await http.get(Uri.parse('$server/api/integrations/available'), headers: headers);
    if (response.statusCode != 200) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(response.body));
  }

  Future<List<Map<String, dynamic>>> getUserIntegrations() async {
    final server = await _serverUrl;
    final headers = await _headers;
    final response = await http.get(Uri.parse('$server/api/integrations'), headers: headers);
    if (response.statusCode != 200) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(response.body));
  }

  Future<void> createIntegration(String provider, Map<String, dynamic> config) async {
    final server = await _serverUrl;
    final headers = await _headers;
    await http.post(
      Uri.parse('$server/api/integrations'),
      headers: headers,
      body: jsonEncode({'provider': provider, 'config': config, 'enabled': true}),
    );
  }

  Future<void> updateIntegration(String id, {bool? enabled, Map<String, dynamic>? config}) async {
    final server = await _serverUrl;
    final headers = await _headers;
    final body = <String, dynamic>{};
    if (enabled != null) body['enabled'] = enabled;
    if (config != null) body['config'] = config;
    await http.patch(Uri.parse('$server/api/integrations/$id'), headers: headers, body: jsonEncode(body));
  }

  Future<String> getOAuthUrl(String provider) async {
    final server = await _serverUrl;
    final headers = await _headers;
    final response = await http.get(
      Uri.parse('$server/api/integrations/oauth/$provider/authorize'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      var message = 'OAuth request failed (${response.statusCode})';
      try {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic> && data['detail'] is String) {
          message = data['detail'];
        }
      } catch (_) {}
      throw Exception(message);
    }

    final data = jsonDecode(response.body);
    final authorizeUrl = data['authorize_url'];
    if (authorizeUrl is! String || authorizeUrl.isEmpty) {
      throw Exception('OAuth authorization URL missing');
    }
    return authorizeUrl;
  }

  // --- Rules ---

  Future<List<Map<String, dynamic>>> getRules() async {
    final server = await _serverUrl;
    final headers = await _headers;
    final response = await http.get(Uri.parse('$server/api/rules'), headers: headers);
    if (response.statusCode != 200) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(response.body));
  }

  Future<List<Map<String, dynamic>>> getRuleTemplates() async {
    final server = await _serverUrl;
    final headers = await _headers;
    final response = await http.get(Uri.parse('$server/api/rules/templates/examples'), headers: headers);
    if (response.statusCode != 200) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(response.body));
  }

  Future<Map<String, dynamic>?> createRule(Map<String, dynamic> rule) async {
    final server = await _serverUrl;
    final headers = await _headers;
    final response = await http.post(
      Uri.parse('$server/api/rules'),
      headers: headers,
      body: jsonEncode(rule),
    );
    if (response.statusCode != 201) return null;
    return jsonDecode(response.body);
  }

  Future<void> updateRule(String id, {bool? enabled, String? name, Map<String, dynamic>? conditions, List? actions}) async {
    final server = await _serverUrl;
    final headers = await _headers;
    final body = <String, dynamic>{};
    if (enabled != null) body['enabled'] = enabled;
    if (name != null) body['name'] = name;
    if (conditions != null) body['conditions'] = conditions;
    if (actions != null) body['actions'] = actions;
    await http.patch(Uri.parse('$server/api/rules/$id'), headers: headers, body: jsonEncode(body));
  }

  Future<void> deleteRule(String id) async {
    final server = await _serverUrl;
    final headers = await _headers;
    await http.delete(Uri.parse('$server/api/rules/$id'), headers: headers);
  }

  /// Upload an audio segment to the backend (used by BLE relay)
  Future<bool> uploadSegment({
    required List<int> audioData,
    required String recordedAt,
    required int durationMs,
    int? silenceBeforeMs,
    int? audioEnergy,
  }) async {
    final server = await _serverUrl;
    String? key;
    try {
      key = await _secureStorage.read(key: _apiKeyKey);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      key = prefs.getString(_apiKeyKey);
    }

    final uri = Uri.parse('$server/api/segments');
    debugPrint('[API] uploadSegment start uri=$uri recordedAt=$recordedAt durationMs=$durationMs audioBytes=${audioData.length}');
    final request = http.MultipartRequest('POST', uri);
    request.headers['X-API-Key'] = key ?? '';
    request.headers['X-Recorded-At'] = recordedAt;
    request.headers['X-Duration-Ms'] = durationMs.toString();
    if (silenceBeforeMs != null) {
      request.headers['X-Silence-Before-Ms'] = silenceBeforeMs.toString();
    }
    if (audioEnergy != null) {
      request.headers['X-Audio-Energy'] = audioEnergy.toString();
    }

    request.files.add(http.MultipartFile.fromBytes(
      'audio',
      audioData,
      filename: 'segment.adpcm',
    ));

    final client = http.Client();
    try {
      final statusCode = await (() async {
        final streamedResponse = await client.send(request);
        await streamedResponse.stream.drain<void>();
        return streamedResponse.statusCode;
      })().timeout(_segmentUploadTimeout);
      debugPrint('[API] uploadSegment response status=$statusCode');
      return statusCode == 201;
    } finally {
      client.close();
    }
  }
}


// --- Conversation Models ---

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
