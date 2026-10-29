import 'package:http/http.dart' as http;

import '../../models/memory_items.dart';
import 'api_client.dart';

/// Profile → Memory → About you.
abstract interface class AboutYouApi {
  Future<UserFacts> getFacts();
  Future<UserFact> addFact(String text);
  Future<UserFact> editFact(String id, String text);
  Future<UserFact> keepFact(String id);

  /// Deletes a kept fact, or discards a suggestion.
  Future<void> deleteFact(String id);
}

/// Profile → Memory → Documents.
abstract interface class DocumentsApi {
  Future<List<UserDocument>> listDocuments();
  Future<UserDocument> uploadDocument(String filename, List<int> bytes);
  Future<UserDocument> getDocument(String id);
  Future<void> deleteDocument(String id);
}

mixin MemoryItemsEndpoints on ApiClient implements AboutYouApi, DocumentsApi {
  @override
  Future<UserFacts> getFacts() async {
    final response = await get('/api/facts');
    return parse(response.data, (data) => UserFacts.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<UserFact> addFact(String text) async {
    final response = await post('/api/facts', body: {'text': text}, expect: const {201});
    return parse(response.data, (data) => UserFact.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<UserFact> editFact(String id, String text) async {
    final response = await patch('/api/facts/$id', body: {'text': text});
    return parse(response.data, (data) => UserFact.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<UserFact> keepFact(String id) async {
    final response = await post('/api/facts/$id/keep');
    return parse(response.data, (data) => UserFact.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<void> deleteFact(String id) => delete('/api/facts/$id');

  @override
  Future<List<UserDocument>> listDocuments() async {
    final response = await get('/api/documents');
    return parse(response.data, (data) {
      final items = (data as Map<String, dynamic>)['documents'] as List<dynamic>? ?? const [];
      return [
        for (final item in items)
          if (item is Map<String, dynamic>) UserDocument.fromJson(item),
      ];
    });
  }

  @override
  Future<UserDocument> uploadDocument(String filename, List<int> bytes) async {
    final request = (await multipart('POST', '/api/documents'))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await upload(request);
    if (response.statusCode != 201) throw statusException(response.statusCode, response.body);
    return UserDocument.fromJson(
      decodeJson(response.body, shape: JsonShape.map) as Map<String, dynamic>,
    );
  }

  @override
  Future<UserDocument> getDocument(String id) async {
    final response = await get('/api/documents/$id');
    return parse(response.data, (data) => UserDocument.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<void> deleteDocument(String id) => delete('/api/documents/$id');
}
