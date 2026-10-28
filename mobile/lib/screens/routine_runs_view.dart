import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/routine.dart';
import '../models/routine_run.dart';
import '../services/api/routines_api.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import '../widgets/panel.dart';
import '../widgets/routine_run_sheet.dart';
import '../widgets/sections.dart';

/// Ask → Routines: what the routines found, by day, newest first, each in full with its
/// sources and "Ask about this"; quiet and missed runs as one muted line. Chips filter on
/// one routine; earlier results load at the end.
final class RoutineRunsView extends StatefulWidget {
  const RoutineRunsView({
    required this.api,
    required this.onFilter,
    required this.onAskAbout,
    this.routineId,
    this.changes,
    super.key,
  });

  final RoutinesApi api;

  /// The routine shown; null: all of them.
  final String? routineId;
  final ValueChanged<String?> onFilter;
  final Future<void> Function(RoutineRun run) onAskAbout;

  /// Counts up when new runs arrive: the list reloads.
  final ValueListenable<int>? changes;

  @override
  State<RoutineRunsView> createState() => _RoutineRunsViewState();
}

final class _RoutineRunsViewState extends State<RoutineRunsView> {
  List<Routine> _routines = const [];
  List<RoutineRun> _runs = const [];
  DateTime? _nextBefore;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_reload);
    unawaited(_load(first: true));
    unawaited(_loadRoutines());
  }

  @override
  void didUpdateWidget(covariant RoutineRunsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes?.removeListener(_reload);
      widget.changes?.addListener(_reload);
    }
    if (oldWidget.routineId != widget.routineId) unawaited(_load());
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_reload);
    _generation++;
    super.dispose();
  }

  void _reload() {
    unawaited(_load());
    unawaited(_loadRoutines());
  }

  Future<void> _loadRoutines() async {
    try {
      final routines = await widget.api.listRoutines();
      if (mounted) setState(() => _routines = routines);
    } catch (_) {}
  }

  Future<void> _load({bool first = false}) async {
    final generation = ++_generation;
    if (!first) {
      setState(() {
        _loading = _runs.isEmpty;
        _error = null;
      });
    }
    try {
      final page = await widget.api.listRoutineRuns(routineId: widget.routineId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _runs = page.items;
        _nextBefore = page.nextBefore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the results.';
      });
    }
  }

  Future<void> _loadMore() async {
    final before = _nextBefore;
    if (before == null || _loadingMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.api.listRoutineRuns(routineId: widget.routineId, before: before);
      if (!mounted || generation != _generation) return;
      setState(() {
        _runs = [..._runs, ...page.items];
        _nextBefore = page.nextBefore;
      });
    } catch (_) {
      // The button stays: another tap tries again
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final rows = <Widget>[];
    DateTime? day;
    for (final run in _runs) {
      final runDay = dayOf(run.ranAt);
      if (runDay != day) {
        day = runDay;
        rows.add(_DayLabel(dayLabel(run.ranAt, now)));
      }
      rows.add(_RunEntry(run: run, onAskAbout: () => widget.onAskAbout(run)));
    }
    return ListView(
      key: const Key('routine-runs'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (_routines.length > 1)
          _Filters(
            routines: _routines,
            selected: widget.routineId,
            onSelected: widget.onFilter,
          ),
        if (_loading)
          const SectionLoading(label: 'Loading results')
        else if (_error != null)
          SectionError(
            message: _error!,
            retryKey: const Key('routines-retry'),
            onRetry: () => unawaited(_load()),
          )
        else if (_runs.isEmpty)
          const SectionEmpty(message: "Your routines' results show up here.")
        else ...[
          ...rows,
          if (_nextBefore != null)
            Center(
              child: TextButton(
                key: const Key('routines-more'),
                onPressed: _loadingMore ? null : () => unawaited(_loadMore()),
                child: const Text('Show earlier'),
              ),
            ),
        ],
      ],
    );
  }
}

final class _Filters extends StatelessWidget {
  const _Filters({required this.routines, required this.selected, required this.onSelected});

  final List<Routine> routines;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    // Each chip says its routine in full: the row scrolls instead of cutting it
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          ChoiceChip(
            key: const Key('routines-filter-all'),
            label: const Text('All'),
            selected: selected == null,
            onSelected: (_) => onSelected(null),
          ),
          for (final routine in routines) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              key: Key('routines-filter-${routine.id}'),
              label: Text(routine.instruction),
              selected: selected == routine.id,
              onSelected: (_) => onSelected(routine.id),
            ),
          ],
        ],
      ),
    );
  }
}

final class _DayLabel extends StatelessWidget {
  const _DayLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: EchoPalette.of(context).text2,
            ),
      ),
    );
  }
}

final class _RunEntry extends StatelessWidget {
  const _RunEntry({required this.run, required this.onAskAbout});

  final RoutineRun run;
  final Future<void> Function() onAskAbout;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.bodySmall?.copyWith(color: palette.text2);
    final time = formatTime(run.ranAt);
    if (run.status == 'nothing') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text('$time · ${run.instruction}: checked, nothing new', style: muted),
      );
    }
    if (run.status == 'skipped') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text('${routineMissedLine(run)} (${run.instruction})', style: muted),
      );
    }
    final failed = run.status == 'failed';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        key: Key('routine-entry-${run.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(run.instruction, style: textTheme.titleSmall),
            const SizedBox(height: 2),
            Text('$time · ${routineModeText(run.mode)}', style: muted),
            const SizedBox(height: 10),
            Text(
              run.text ?? (failed ? 'Could not run' : ''),
              style: textTheme.bodyMedium?.copyWith(color: failed ? palette.red : null),
            ),
            if (run.sources.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final source in run.sources) RoutineSourceRow(source),
            ],
            if (!failed && run.hasText)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('ask-about-${run.id}'),
                  onPressed: () => unawaited(onAskAbout()),
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: const Text('Ask about this'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
