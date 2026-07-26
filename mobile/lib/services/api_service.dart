import 'dart:convert';
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

  final _secureStorage = const FlutterSecureStorage();

  Future<bool> isConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString(_serverKey);
    final key = await _secureStorage.read(key: _apiKeyKey);
    return server != null && server.isNotEmpty && key != null && key.isNotEmpty;
  }

  Future<void> configure(String serverUrl, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, serverUrl.trimRight());
    await _secureStorage.write(key: _apiKeyKey, value: apiKey.trim());
  }

  Future<String> get _serverUrl async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverKey) ?? '';
  }

  Future<Map<String, String>> get _headers async {
    final key = await _secureStorage.read(key: _apiKeyKey) ?? '';
    return {
      'X-API-Key': key,
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
}
