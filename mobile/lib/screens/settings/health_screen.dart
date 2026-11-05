import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/api/api_exception.dart';
import '../../services/api/health_api.dart';
import '../../theme/app_theme.dart';
import 'settings_components.dart';

/// "6 h 50".
String sleepText(int minutes) => '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';

/// Profile → Health: the iPhone's Health app reaches Echo through Apple's Shortcuts (the
/// app, signed with a free Apple ID, cannot read it). Here: the days received, the key for
/// the shortcut (shown once) and Delete. The steps are in docs/HEALTH-SHORTCUT.md.
final class HealthScreen extends StatefulWidget {
  const HealthScreen({required this.api, super.key});

  final HealthApi api;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

final class _HealthScreenState extends State<HealthScreen> {
  List<HealthDayInfo>? _days;
  ShortcutKey? _key;
  String? _server;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final days = await widget.api.healthDays();
      if (mounted) setState(() => _days = days);
    } catch (error) {
      if (mounted) {
        setState(() {
          _days ??= const [];
          _error = userMessage(error, 'Could not load the days.');
        });
      }
    }
  }

  Future<void> _makeKey() async {
    if (_key != null) {
      final again = await _confirm(
        'A new key?',
        'The shortcut stops working until you paste the new key in it.',
        'New key',
      );
      if (!again) return;
    }
    await _run(() async {
      final key = await widget.api.makeHealthKey();
      final server = await widget.api.getServerUrl();
      if (mounted) {
        setState(() {
          _key = key;
          _server = server;
        });
      }
    }, 'Could not make the key.');
  }

  Future<void> _forget() async {
    final sure = await _confirm(
      'Delete health data?',
      'Echo forgets every day received, and the shortcut’s key stops working.',
      'Delete',
    );
    if (!sure) return;
    await _run(() async {
      await widget.api.forgetHealth();
      if (mounted) {
        setState(() {
          _days = const [];
          _key = null;
        });
      }
    }, 'Could not delete them.');
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  Future<void> _copy(String what, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final days = _days;
    final key = _key;
    return SettingsPageScaffold(
      title: 'Health',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'Sleep, steps, distance and exercise from the iPhone’s Health app, sent each '
            'evening by an automation in Shortcuts. Echo uses the last two weeks in its '
            'answers and charts.',
            style: textTheme.bodyMedium?.copyWith(color: palette.text2),
          ),
        ),
        const SettingsSection('RECEIVED'),
        if (days == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          SettingsGroup(children: [
            if (days.isEmpty)
              Padding(
                key: const Key('health-empty'),
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Nothing yet. Make the key below and set up the shortcut.',
                  style: textTheme.bodyMedium?.copyWith(color: palette.text2),
                ),
              ),
            for (final day in days.take(7))
              Padding(
                key: Key('health-day-${day.day.toIso8601String().substring(0, 10)}'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        MaterialLocalizations.of(context).formatShortMonthDay(day.day),
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 14,
                        runSpacing: 4,
                        children: [
                          if (day.sleepMinutes case final sleep?)
                            _Stat(Icons.bedtime_outlined, sleepText(sleep)),
                          if (day.steps case final steps?)
                            _Stat(Icons.directions_walk_rounded, '$steps'),
                          if (day.exerciseMinutes case final minutes?)
                            _Stat(Icons.local_fire_department_outlined, '$minutes min'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ]),
        const SettingsSection('THE SHORTCUT'),
        if (key == null)
          SettingsRow(
            key: const Key('health-make-key'),
            icon: Icons.key_rounded,
            title: 'Create the key for Shortcuts',
            subtitle: 'It can only send these numbers: nothing else of yours.',
            onTap: _busy ? null : () => unawaited(_makeKey()),
          )
        else
          Container(
            key: const Key('health-key'),
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: BorderRadius.circular(AppTheme.panelRadius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Paste these in the shortcut’s “Get contents of URL”. The key is '
                  'shown only now.',
                  style: textTheme.bodySmall?.copyWith(color: palette.onAccentSoft),
                ),
                const SizedBox(height: 12),
                _Copyable(
                  label: 'URL (POST)',
                  value: '${_server ?? ''}${key.path}',
                  onCopy: (v) => _copy('The URL', v),
                ),
                const SizedBox(height: 10),
                _Copyable(
                  label: 'Header X-API-Key',
                  value: key.apiKey,
                  onCopy: (v) => _copy('The key', v),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _busy ? null : () => unawaited(_makeKey()),
                    child: const Text('New key'),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text(
            'In Shortcuts → Automation: every day at 22:30, find the Health samples of today '
            '(sleep, steps, distance, exercise), add them up, and send them as JSON with '
            '"Get contents of URL": date, sleep, steps, distance, exercise_minutes. '
            'The full steps are in the guide, docs/HEALTH-SHORTCUT.md.',
            style: textTheme.bodySmall?.copyWith(color: palette.text2),
          ),
        ),
        if (_error case final error?) SettingsMessage(error, error: true),
        const SizedBox(height: 16),
        SettingsRow(
          key: const Key('health-forget'),
          icon: Icons.delete_outline_rounded,
          title: 'Delete health data',
          destructive: true,
          onTap: _busy ? null : () => unawaited(_forget()),
        ),
      ],
    );
  }
}

final class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: palette.accent),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

final class _Copyable extends StatelessWidget {
  const _Copyable({required this.label, required this.value, required this.onCopy});

  final String label;
  final String value;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: textTheme.labelSmall?.copyWith(color: palette.onAccentSoft)),
              const SizedBox(height: 2),
              SelectableText(
                value,
                style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        IconButton(
          key: Key('health-copy-$label'),
          tooltip: 'Copy',
          onPressed: () => onCopy(value),
          icon: Icon(Icons.copy_rounded, size: 18, color: palette.onAccentSoft),
        ),
      ],
    );
  }
}
