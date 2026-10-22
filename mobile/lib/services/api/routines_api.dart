import '../../models/routine.dart';
import 'api_client.dart';

/// Routines: what Echo does on its own, and when (created by asking Echo).
abstract interface class RoutinesApi {
  Future<List<Routine>> listRoutines();

  /// Pause or resume; resuming counts from now.
  Future<Routine> setRoutineActive(String id, bool active);

  Future<void> deleteRoutine(String id);
}

mixin RoutineEndpoints on ApiClient implements RoutinesApi {
  @override
  Future<List<Routine>> listRoutines() async {
    final response = await get('/api/routines', shape: JsonShape.list);
    return parse(
      response.data,
      (data) => [
        for (final item in data as List<dynamic>) Routine.fromJson(item as Map<String, dynamic>),
      ],
    );
  }

  @override
  Future<Routine> setRoutineActive(String id, bool active) async {
    final response = await patch('/api/routines/$id', body: {'active': active});
    return parse(response.data, (data) => Routine.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<void> deleteRoutine(String id) => delete('/api/routines/$id');
}
