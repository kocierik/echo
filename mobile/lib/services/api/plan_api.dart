import '../../models/plan.dart';
import 'api_client.dart';

/// The account's plan and this month's speech (Profile → Plan, Today's line).
abstract interface class PlanApi {
  Future<PlanInfo> getPlan();
}

mixin PlanEndpoints on ApiClient implements PlanApi {
  @override
  Future<PlanInfo> getPlan() async {
    final response = await get('/api/plan');
    return parse(response.data, (data) => PlanInfo.fromJson(data as Map<String, dynamic>));
  }
}
