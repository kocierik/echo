import '../utils/formatting.dart';

/// The account's plan and this month's speech (GET /api/plan): Profile → Plan, and
/// Today's line near and past the budget. The month is the calendar month in UTC.
final class PlanInfo {
  const PlanInfo({
    required this.plan,
    required this.monthlySeconds,
    required this.usedSeconds,
    required this.dailySeconds,
    required this.deferredSeconds,
    required this.resetsOn,
    required this.overBudget,
    required this.webSearchesPerDay,
    required this.routines,
    this.premiumVoice = false,
  });

  factory PlanInfo.fromJson(Map<String, dynamic> json) {
    final resets = DateTime.parse(json['resets_on'] as String);
    return PlanInfo(
      plan: json['plan'] as String,
      monthlySeconds: (json['monthly_seconds'] as num).toInt(),
      usedSeconds: (json['used_seconds'] as num).toInt(),
      dailySeconds: (json['daily_seconds'] as num).toInt(),
      deferredSeconds: (json['deferred_seconds'] as num?)?.toInt() ?? 0,
      resetsOn: DateTime(resets.year, resets.month, resets.day),
      overBudget: json['over_budget'] as bool? ?? false,
      webSearchesPerDay: (json['web_searches_per_day'] as num).toInt(),
      routines: (json['routines'] as num).toInt(),
      premiumVoice: json['premium_voice'] as bool? ?? false,
    );
  }

  /// "free", "plus", "unlimited".
  final String plan;
  final int monthlySeconds;
  final int usedSeconds;

  /// Past the budget, still transcribed each day at once.
  final int dailySeconds;

  /// Speech kept and waiting for the budget.
  final int deferredSeconds;

  /// The day the budget starts again.
  final DateTime resetsOn;
  final bool overBudget;
  final int webSearchesPerDay;
  final int routines;

  /// Spoken answers may use Echo's natural voices (Plus and Unlimited).
  final bool premiumVoice;

  /// "Plus".
  String get name => plan.isEmpty ? plan : '${plan[0].toUpperCase()}${plan.substring(1)}';

  /// "12 h of 25 h this month".
  String get usageLine => '${speechAmount(usedSeconds)} of ${speechAmount(monthlySeconds)} this month';

  /// Four fifths of the budget used, not all of it: Today says so before it runs out.
  bool get nearBudget => !overBudget && monthlySeconds > 0 && usedSeconds * 5 >= monthlySeconds * 4;

  /// "10 minutes".
  String get dailyAllowance {
    final minutes = dailySeconds ~/ 60;
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }
}
