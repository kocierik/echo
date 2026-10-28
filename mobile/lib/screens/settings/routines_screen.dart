import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/routine.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/formatting.dart';
import '../../widgets/expandable_text.dart';
import '../../widgets/panel.dart';

/// Profile → Routines: what Echo does on its own, and when. Routines are created by
/// asking Echo; here they are paused, resumed or deleted.
class RoutinesScreen extends StatefulWidget {
  const RoutinesScreen({this.api, this.clock = DateTime.now, super.key});

  /// Injected API (not disposed by the screen); a private one is created when omitted.
  final RoutinesApi? api;
  final DateTime Function() clock;

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
  });

  final Routine routine;
  final DateTime now;
  final ValueChanged<bool> onActive;
  final VoidCallback onDelete;

  String? get _last => switch (routine.lastStatus) {
        'ok' => routine.lastAnswer,
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
                const SizedBox(height: 2),
                Text(routine.scheduleText,
                    style: textTheme.labelMedium?.copyWith(color: palette.accent)),
                const SizedBox(height: 2),
                Text(next, style: textTheme.bodySmall?.copyWith(color: palette.text2)),
                if (last != null) ...[
                  const SizedBox(height: 6),
                  ExpandableText(
                    last,
                    key: Key('routine-last-${routine.id}'),
                    style: textTheme.bodySmall?.copyWith(
                      color: routine.lastStatus == 'ok' ? palette.text : palette.red,
                    ),
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
