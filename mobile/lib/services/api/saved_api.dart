import '../../models/saved.dart';
import 'api_client.dart';

/// Saved: things the user asked Echo to keep and find again (saved by asking Echo; here
/// they are seen, moved and removed).
abstract interface class SavedApi {
  Future<SavedOverview> getSaved();

  /// The things whose words match [query].
  Future<List<SavedItem>> searchSaved(String query);

  Future<SavedListDetail> getSavedList(String id);

  /// Every list, empty ones too ("Move to…").
  Future<List<SavedListChoice>> listSavedLists();

  Future<SavedItemDetail> getSavedItem(String id);

  /// Moves a thing to the list called [list] (started when new).
  Future<SavedItem> moveSavedItem(String id, String list);

  /// "Found it" and "Remove from Saved": the thing only, never its photo.
  Future<void> deleteSavedItem(String id);

  /// The place the phone could read only once Echo was opened.
  Future<SavedItem> putSavedPlace(String id, SavedPlace place);
}

mixin SavedEndpoints on ApiClient implements SavedApi {
  @override
  Future<SavedOverview> getSaved() async {
    final response = await get('/api/saved');
    return parse(response.data, (data) => SavedOverview.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<List<SavedItem>> searchSaved(String query) async {
    final response = await get('/api/saved?q=${Uri.encodeQueryComponent(query)}');
    return parse(response.data, (data) {
      final results = (data as Map<String, dynamic>)['results'];
      if (results is! List<dynamic>) throw const FormatException('results');
      return [for (final item in results) SavedItem.fromJson(item as Map<String, dynamic>)];
    });
  }

  @override
  Future<SavedListDetail> getSavedList(String id) async {
    final response = await get('/api/saved/lists/${Uri.encodeComponent(id)}');
    return parse(response.data, (data) => SavedListDetail.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<List<SavedListChoice>> listSavedLists() async {
    final response = await get('/api/saved/lists', shape: JsonShape.list);
    return parse(
      response.data,
      (data) => [
        for (final item in data as List<dynamic>)
          SavedListChoice.fromJson(item as Map<String, dynamic>),
      ],
    );
  }

  @override
  Future<SavedItemDetail> getSavedItem(String id) async {
    final response = await get('/api/saved/items/${Uri.encodeComponent(id)}');
    return parse(response.data, (data) => SavedItemDetail.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<SavedItem> moveSavedItem(String id, String list) async {
    final response = await patch('/api/saved/items/${Uri.encodeComponent(id)}', body: {'list': list});
    return parse(response.data, (data) => SavedItem.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<void> deleteSavedItem(String id) => delete('/api/saved/items/${Uri.encodeComponent(id)}');

  @override
  Future<SavedItem> putSavedPlace(String id, SavedPlace place) async {
    final response = await put(
      '/api/saved/items/${Uri.encodeComponent(id)}/place',
      body: place.toJson(),
    );
    return parse(response.data, (data) => SavedItem.fromJson(data as Map<String, dynamic>));
  }
}
