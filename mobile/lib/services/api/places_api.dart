import '../../models/place.dart';
import 'api_client.dart';

/// Places visited (Profile → Places visited): the phone's stays go up in batches; the
/// visits kept are listed and deleted here.
abstract interface class PlacesApi {
  /// Sends stays; [source] "ios" or "android". The server keeps one visit per key.
  Future<void> postVisits(List<RecordedVisit> visits, {required String source});

  /// The visits, newest first; [before] for the next page.
  Future<VisitPage> listVisits({DateTime? before});

  Future<void> deleteVisit(String id);

  /// The visits that started on [day].
  Future<void> deleteVisitDay(DateTime day);

  Future<void> deleteAllVisits();
}

mixin PlacesEndpoints on ApiClient implements PlacesApi {
  @override
  Future<void> postVisits(List<RecordedVisit> visits, {required String source}) async {
    await post('/api/places/visits', body: {
      'source': source,
      'visits': [for (final visit in visits) visit.toJson()],
    });
  }

  @override
  Future<VisitPage> listVisits({DateTime? before}) async {
    final query = before == null
        ? ''
        : '?before=${Uri.encodeQueryComponent(before.toUtc().toIso8601String())}';
    final response = await get('/api/places/visits$query');
    return parse(response.data, (data) => VisitPage.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<void> deleteVisit(String id) =>
      delete('/api/places/visits/${Uri.encodeComponent(id)}');

  @override
  Future<void> deleteVisitDay(DateTime day) {
    final date = '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    return delete('/api/places/days/$date', expect: const {200});
  }

  @override
  Future<void> deleteAllVisits() => delete('/api/places/visits', expect: const {200});
}
