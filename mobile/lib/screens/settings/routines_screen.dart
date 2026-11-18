import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/routine.dart';
import '../../models/routine_run.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/formatting.dart';
import '../../widgets/panel.dart';
import '../../widgets/routine_run_sheet.dart';
import '../navigation.dart';

/// Profile → Routines: what Echo does on its own, when, and when it speaks. Routines are
/// created by asking Echo; here they are paused, resumed or deleted, and lead to what
/// they found: the last result in full, and all of them in Ask → Routines.
class RoutinesScreen extends StatefulWidget {
  const RoutinesScreen({
    this.api,
    this.clock = DateTime.now,
    this.onOpenResults,
    this.onOpenThread,
    super.key,
  });

  /// Injected API (not disposed by the screen); a private one is created when omitted.
  final RoutinesApi? api;
  final DateTime Function() clock;

  /// Ask → Routines on one routine (its id); this screen closes first.
  final void Function(String routineId)? onOpenResults;

  /// Ask on the thread with Echo (its session id), after "Ask about this".
  final void Function(String sessionId)? onOpenThread;

  @override
  State<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends State<RoutinesScreen> {
  ApiService? _own;
  late final RoutinesApi _api = widget.api ?? (_own = ApiService());
  List<Routine> _routines = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final routines = await _api.listRoutines();
      if (!mounted) return;
      setState(() {
        _routines = routines;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : 'Could not load your routines.';
      });
    }
  }

  void _replace(Routine routine) {
    setState(() {
      _routines = [for (final r in _routines) r.id == routine.id ? routine : r];
    });
  }

  Future<void> _setActive(Routine routine, bool active) async {
    _replace(routine.copyWith(active: active));
    try {
      _replace(await _api.setRoutineActive(routine.id, active));
    } catch (_) {
      if (!mounted) return;
      _replace(routine);
      _say(active ? 'Could not resume the routine.' : 'Could not pause the routine.');
    }
  }

  Future<void> _delete(Routine routine) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this routine?'),
            content: Text('Echo will stop: "${routine.instruction}".'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      await _api.deleteRoutine(routine.id);
      if (!mounted) return;
      setState(() => _routines = _routines.where((r) => r.id != routine.id).toList());
    } catch (_) {
      if (mounted) _say('Could not delete the routine.');
    }
  }

  /// Back to the app's tabs, where Ask is.
  void _closeToTabs() => popToTabs(context);

  void _openResults(Routine routine) {
    final open = widget.onOpenResults;
    if (open == null) return;
    _closeToTabs();
    open(routine.id);
  }

  /// The last result in full: its run, or what the routine kept from before runs.
  Future<void> _openLast(Routine routine) async {
    RoutineRun? latest;
    try {
      final page = await _api.listRoutineRuns(routineId: routine.id, limit: 1);
      latest = page.items.isEmpty ? null : page.items.first;
    } catch (_) {}
    if (!mounted) return;
    final run = latest ??
        RoutineRun(
          id: '',
          routineId: routine.id,
          instruction: routine.instruction,
          mode: routine.mode,
          scheduleText: routine.scheduleText,
          ranAt: routine.lastRunAt ?? widget.clock(),
          status: routine.lastStatus ?? 'reported',
          text: routine.lastAnswer,
        );
    final open = widget.onOpenThread;
    await showRoutineRunSheet(
      context,
      run,
      onAskAbout: latest == null || open == null ? null : () => _askAbout(run, open),
    );
  }

  Future<void> _askAbout(RoutineRun run, void Function(String) open) async {
    try {
      final thread = await _api.askAboutRoutineRun(run.id);
      if (!mounted) return;
      _closeToTabs();
      open(thread);
    } catch (_) {
      if (mounted) _say('Could not open it in Ask.');
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Routines')),
      body: _body(palette),
    );
  }

  Widget _body(EchoPalette palette) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: palette.text2)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final textTheme = Theme.of(context).textTheme;
    final note = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Text(
        'Results arrive as a notification while Echo is running on this phone, '
        'otherwise when you next open it.',
        style: textTheme.bodySmall?.copyWith(color: palette.text2),
      ),
    );
    if (_routines.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Text(
              "No routines yet. Ask Echo to set one up: 'Hey Echo, every morning at 7 "
              "tell me the weather in Milan.'",
              style: textTheme.bodyMedium?.copyWith(color: palette.text2),
            ),
          ),
          note,
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final (index, routine) in _routines.indexed)
          PanelListRow(
            index: index,
            count: _routines.length,
            child: _RoutineTile(
              routine: routine,
              now: widget.clock(),
              onActive: (active) => unawaited(_setActive(routine, active)),
              onDelete: () => unawaited(_delete(routine)),
              onOpenLast: () => unawaited(_openLast(routine)),
              onOpenResults: widget.onOpenResults == null ? null : () => _openResults(routine),
            ),
          ),
        note,
      ],
    );
  }
}

final class _RoutineTile extends StatelessWidget {
  const _RoutineTile({
    required this.routine,
    required this.now,
    required this.onActive,
    required this.onDelete,
    required this.onOpenLast,
    this.onOpenResults,
  });

  final Routine routine;
  final DateTime now;
  final ValueChanged<bool> onActive;
  final VoidCallback onDelete;

  /// The last result in full, in a sheet.
  final VoidCallback onOpenLast;

  /// Every result, in Ask → Routines.
  final VoidCallback? onOpenResults;

  String? get _last => switch (routine.lastStatus) {
        'reported' => routine.lastAnswer,
        'nothing' => 'Checked, nothing new',
        'failed' => 'Could not run',
        'skipped' => 'Missed while Echo was offline',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final next = routine.active
        ? 'Next: ${dayLabel(routine.nextRunAt, now)} at ${formatTime(routine.nextRunAt)}'
        : 'Paused';
    final last = _last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(routine.instruction, style: textTheme.bodyLarge),
                if (routine.assistant != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Runs as ${routine.assistant!.label}',
                    key: Key('routine-assistant-${routine.id}'),
                    style: textTheme.bodySmall?.copyWith(color: palette.text2),
                  ),
                ],
                const SizedBox(height: 2),
                Text(routine.scheduleText,
                    style: textTheme.labelMedium?.copyWith(color: palette.accent)),
                const SizedBox(height: 2),
                Text(routineModeText(routine.mode),
                    style: textTheme.bodySmall?.copyWith(color: palette.text2)),
                const SizedBox(height: 2),
                Text(next, style: textTheme.bodySmall?.copyWith(color: palette.text2)),
                if (last != null) ...[
                  const SizedBox(height: 6),
                  // Two lines; the sheet behind them has it all
                  InkWell(
                    key: Key('routine-last-${routine.id}'),
                    onTap: onOpenLast,
                    child: Text(
                      last,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: switch (routine.lastStatus) {
                          'reported' => palette.text,
                          'failed' => palette.red,
                          _ => palette.text2,
                        },
                      ),
                    ),
                  ),
                  if (onOpenResults != null)
                    TextButton(
                      key: Key('routine-results-${routine.id}'),
                      onPressed: onOpenResults,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 36),
                        alignment: Alignment.centerLeft,
                      ),
                      child: const Text('See all results'),
                    ),
                ],
              ],
            ),
          ),
          Switch(
            key: Key('routine-${routine.id}'),
            value: routine.active,
            onChanged: onActive,
          ),
          IconButton(
            tooltip: 'Delete routine',
            icon: Icon(Icons.delete_outline_rounded, color: palette.text2),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
