import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/plan.dart';
import '../../services/api/plan_api.dart';
import '../../theme/app_theme.dart';
import '../../utils/formatting.dart';
import '../../widgets/panel.dart';
import 'settings_components.dart';

/// Profile → Plan: the plan, this month's speech and when it starts again, what happens
/// past the budget (nothing is lost: Echo slows down), the speech waiting, and the plan's
/// limits. Plans are set on the server for now; there is nothing to buy here.
final class PlanScreen extends StatefulWidget {
  const PlanScreen({required this.api, this.initial, super.key});

  final PlanApi api;

  /// Shown while the server answers.
  final PlanInfo? initial;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

final class _PlanScreenState extends State<PlanScreen> {
  late PlanInfo? _plan = widget.initial;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final plan = await widget.api.getPlan();
      if (mounted) setState(() => _plan = plan);
    } catch (_) {
      if (mounted && _plan == null) {
        setState(() => _error = 'Echo could not load the plan. Check the connection and try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (plan == null) {
      return SettingsPageScaffold(
        title: 'Plan',
        children: [
          if (_error != null)
            SettingsMessage(_error!, error: true)
          else
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      );
    }
    final resets = dayAndMonth(plan.resetsOn);
    return SettingsPageScaffold(
      title: 'Plan',
      children: [
        _UsageCard(plan: plan),
        if (plan.overBudget)
          _Note(
            'This month\'s speech is used. Echo is transcribing ${plan.dailyAllowance} a day '
            'until $resets.',
            strong: true,
          ),
        if (plan.deferredSeconds > 0)
          _Note(
            '${speechAmount(plan.deferredSeconds)} of speech waiting: '
            'Echo transcribes it from $resets.',
            strong: true,
          ),
        const SettingsSection('PAST THE BUDGET'),
        _Note(
          'Echo keeps recording and keeps the audio. The first ${plan.dailyAllowance} of '
          'each day are still transcribed at once, so asking Echo by voice keeps working. '
          'The rest waits, and Echo transcribes it from the 1st, oldest first, or as soon '
          'as the plan grows. Nothing is lost.',
        ),
        const SettingsSection('THIS PLAN'),
        SettingsRow(
          icon: Icons.graphic_eq_rounded,
          title: 'Speech',
          value: '${speechAmount(plan.monthlySeconds)} a month',
        ),
        SettingsRow(
          icon: Icons.travel_explore_rounded,
          title: 'Web searches',
          value: '${plan.webSearchesPerDay} a day',
        ),
        SettingsRow(
          icon: Icons.schedule_rounded,
          title: 'Routines',
          value: 'Up to ${plan.routines}',
        ),
        const _Note('Plans cannot be changed in the app yet.'),
      ],
    );
  }
}

/// The plan's name, this month's speech with a bar, and the day it starts again.
final class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.plan});

  final PlanInfo plan;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final share = plan.monthlySeconds == 0
        ? 1.0
        : (plan.usedSeconds / plan.monthlySeconds).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Panel(
        key: const Key('plan-usage'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(plan.name, style: textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(plan.usageLine, style: textTheme.bodyMedium),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: share,
                minHeight: 8,
                backgroundColor: palette.border,
                color: plan.overBudget ? palette.amber : palette.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Starts again on ${dayAndMonth(plan.resetsOn)}.',
              style: textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
          ],
        ),
      ),
    );
  }
}

final class _Note extends StatelessWidget {
  const _Note(this.text, {this.strong = false});

  final String text;

  /// About this month: in the text colour, not muted.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: strong ? palette.text : palette.text2,
            ),
      ),
    );
  }
}
