import 'package:flutter/material.dart';

import '../models/routine_run.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'echo_grouped.dart';
import 'routine_run_sheet.dart';

/// "N checked, nothing new": the runs that had nothing to say.
String quietRunsLine(int count) => '$count checked, nothing new';

/// "From your routines" on Today: what today's runs found, newest first, each opening in
/// full on a tap (the sheet is the page behind its two lines); failed ones in red; the
/// quiet ones counted in one muted line, and a line for each run missed. Nothing without
/// runs.
final class RoutinesTodayPanel extends StatelessWidget {
  const RoutinesTodayPanel({required this.runs, required this.onOpen, super.key});

  final List<RoutineRun> runs;
  final void Function(RoutineRun run) onOpen;

  @override
  Widget build(BuildContext context) {
    if (runs.isEmpty) return const SizedBox.shrink();
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final newest = [...runs]..sort((a, b) => b.ranAt.compareTo(a.ranAt));
    final spoke = [
      for (final run in newest)
        if (run.status == 'reported' || run.status == 'failed') run,
    ];
    final quiet = newest.where((run) => run.status == 'nothing').length;
    final missed = newest.where((run) => run.status == 'skipped');
    final muted = textTheme.bodySmall?.copyWith(color: palette.text2);
    return EchoGroup(
      key: const Key('routines-today'),
      header: 'From your routines',
      children: [
        for (final run in spoke) _RunRow(run: run, onTap: () => onOpen(run)),
        if (quiet > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(quietRunsLine(quiet), key: const Key('routines-quiet'), style: muted),
          ),
        for (final run in missed)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(routineMissedLine(run), style: muted),
          ),
      ],
    );
  }
}

final class _RunRow extends StatelessWidget {
  const _RunRow({required this.run, required this.onTap});

  final RoutineRun run;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final failed = run.status == 'failed';
    return InkWell(
      key: Key('routine-run-${run.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              failed ? 'Could not run' : run.text ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium?.copyWith(color: failed ? palette.red : null),
            ),
            const SizedBox(height: 2),
            Text(
              '${run.instruction} · ${formatTime(run.ranAt)}',
              style: textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
          ],
        ),
      ),
    );
  }
}
