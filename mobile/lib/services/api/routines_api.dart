import '../../models/routine.dart';
import '../../models/routine_run.dart';
import 'api_client.dart';

/// Routines: what Echo does on its own, and when (created by asking Echo).
abstract interface class RoutinesApi {
  Future<List<Routine>> listRoutines();

  /// Pause or resume; resuming counts from now.
  Future<Routine> setRoutineActive(String id, bool active);

  Future<void> deleteRoutine(String id);

  /// The runs, newest first: of one routine, from [since], before [before].
  Future<RoutineRunPage> listRoutineRuns({
    String? routineId,
    DateTime? since,
    DateTime? before,
    int limit = 30,
  });

  /// Puts the run into the thread with Echo ("Ask about this"); returns the thread's id.
  Future<String> askAboutRoutineRun(String runId);
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

  @override
  Future<RoutineRunPage> listRoutineRuns({
    String? routineId,
    DateTime? since,
    DateTime? before,
    int limit = 30,
  }) async {
    final path = Uri(path: '/api/routine-runs', queryParameters: {
      if (routineId != null) 'routine_id': routineId,
      if (since != null) 'since': since.toUtc().toIso8601String(),
      if (before != null) 'before': before.toUtc().toIso8601String(),
      'limit': '$limit',
    }).toString();
    final response = await get(path);
    return parse(
      response.data,
      (data) => RoutineRunPage.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<String> askAboutRoutineRun(String runId) async {
    final response = await post('/api/routine-runs/$runId/ask');
    return parse(
      response.data,
      (data) => (data as Map<String, dynamic>)['session_id'] as String,
    );
  }
}
