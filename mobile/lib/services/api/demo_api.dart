import 'api_client.dart';

/// Profile → Example data: a few days of example conversations, facts, saved things and
/// places, on and off. Off deletes them, and only them.
abstract interface class ExampleDataApi {
  Future<bool> exampleDataOn();

  /// Returns whether it is on now.
  Future<bool> setExampleData(bool on);
}

mixin ExampleDataEndpoints on ApiClient implements ExampleDataApi {
  @override
  Future<bool> exampleDataOn() async {
    final response = await get('/api/demo');
    return parse(response.data, (data) => (data as Map<String, dynamic>)['on'] as bool);
  }

  @override
  Future<bool> setExampleData(bool on) async {
    final response = await put('/api/demo', body: {'on': on});
    return parse(response.data, (data) => (data as Map<String, dynamic>)['on'] as bool);
  }
}
