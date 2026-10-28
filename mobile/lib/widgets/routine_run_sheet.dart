import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/routine.dart';
import '../models/routine_run.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';

/// "Missed at 07:00: Echo's server was off": a run the server could not make.
String routineMissedLine(RoutineRun run) =>
    "Missed at ${formatTime(run.ranAt)}: Echo's server was off";

/// A routine's run in full: the routine, when it ran, the whole answer, its sources and
/// "Ask about this" (which closes the sheet first).
Future<void> showRoutineRunSheet(
  BuildContext context,
  RoutineRun run, {
  required Future<void> Function() onAskAbout,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => RoutineRunSheet(run: run, onAskAbout: onAskAbout),
  );
}

final class RoutineRunSheet extends StatelessWidget {
  const RoutineRunSheet({required this.run, required this.onAskAbout, super.key});

  final RoutineRun run;
  final Future<void> Function() onAskAbout;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final now = DateTime.now();
    final day = dayOf(run.ranAt) == dayOf(now) ? '' : '${dayLabel(run.ranAt, now)}, ';
    final body = switch (run.status) {
      'skipped' =>
        Text(routineMissedLine(run), style: textTheme.bodyLarge?.copyWith(color: palette.text2)),
      'nothing' =>
        Text('Checked, nothing new', style: textTheme.bodyLarge?.copyWith(color: palette.text2)),
      'failed' =>
        Text(run.text ?? 'Could not run', style: textTheme.bodyLarge?.copyWith(color: palette.red)),
      _ => Text(run.text ?? '', style: textTheme.bodyLarge),
    };
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(run.instruction, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '${routineModeText(run.mode)} · $day${formatTime(run.ranAt)}',
            style: textTheme.bodySmall?.copyWith(color: palette.text2),
          ),
          const SizedBox(height: 16),
          body,
          if (run.sources.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Sources', style: textTheme.labelLarge?.copyWith(color: palette.text2)),
            const SizedBox(height: 4),
            for (final source in run.sources) _SourceRow(source),
          ],
          if (run.status == 'reported' && run.hasText) ...[
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const Key('run-ask-about'),
                onPressed: () {
                  Navigator.pop(context);
                  unawaited(onAskAbout());
                },
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Ask about this'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _SourceRow extends StatelessWidget {
  const _SourceRow(this.source);

  final RoutineSource source;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final url = source.url;
    return InkWell(
      onTap: url == null ? null : () => launchUrl(url, mode: LaunchMode.externalApplication),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.link, size: 18, color: palette.text2),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(source.title, style: textTheme.bodyMedium),
                  if (url != null)
                    Text(url.host, style: textTheme.bodySmall?.copyWith(color: palette.text2)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
