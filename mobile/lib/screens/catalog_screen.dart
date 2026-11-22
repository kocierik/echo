import 'dart:async';

import 'package:flutter/material.dart';

import '../models/assistant.dart';
import '../models/routine_catalog.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../theme/app_theme.dart';
import 'settings/settings_components.dart';

enum CatalogTab { routines, assistants }

/// Ready-made routines and assistants, added with one tap: each becomes an ordinary one
/// of the user's, to change or remove like the ones asked for in words. Opened from Ask
/// (Routines' "+ Add", the assistants' "+") and from Routines and Assistants in Settings.
final class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    this.routines,
    this.assistants,
    this.initialTab = CatalogTab.routines,
    this.onRoutinesChanged,
    this.onAssistantsChanged,
    super.key,
  });

  /// Both default to one private connection.
  final RoutineCatalogApi? routines;
  final AssistantsApi? assistants;
  final CatalogTab initialTab;

  /// A routine was added or removed (Ask → Routines reloads).
  final VoidCallback? onRoutinesChanged;

  /// An assistant was added (Ask's row of assistants reloads).
  final VoidCallback? onAssistantsChanged;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

final class _CatalogScreenState extends State<CatalogScreen> {
  ApiService? _owned;
  late final RoutineCatalogApi _routines = widget.routines ?? (_owned ??= ApiService());
  late final AssistantsApi _assistants = widget.assistants ?? (_owned ??= ApiService());
  late CatalogTab _tab = widget.initialTab;

  List<CatalogRoutine>? _catalog;
  List<AssistantTemplate>? _templates;
  Set<String> _assistantNames = const {};
  String? _error;

  /// Keys (routines) and template keys (assistants) being added or removed.
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _routines.routineCatalog(),
        _assistants.assistantTemplates(),
        _assistants.listAssistants(),
      ]);
      if (!mounted) return;
      setState(() {
        _catalog = results[0] as List<CatalogRoutine>;
        _templates = results[1] as List<AssistantTemplate>;
        _assistantNames = {
          for (final a in results[2] as List<Assistant>) a.name.trim().toLowerCase(),
        };
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'Could not load the catalog.'));
    }
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _toggleRoutine(CatalogRoutine entry, {String? time}) async {
    if (_busy.contains(entry.key)) return;
    setState(() => _busy.add(entry.key));
    try {
      if (entry.routineId case final id?) {
        await _routines.deleteRoutine(id);
        _say('${entry.title} removed.');
      } else {
        await _routines.addCatalogRoutine(entry.key, time: time);
        _say('${entry.title} added. Its results show in Ask → Routines.');
      }
      widget.onRoutinesChanged?.call();
      await _load();
    } catch (error) {
      _say(userMessage(error, 'Could not change ${entry.title}.'));
    } finally {
      if (mounted) setState(() => _busy.remove(entry.key));
    }
  }

  bool _hasAssistant(AssistantTemplate template) =>
      _assistantNames.contains(template.name.trim().toLowerCase());

  Future<void> _addAssistant(AssistantTemplate template) async {
    if (_busy.contains(template.key) || _hasAssistant(template)) return;
    setState(() => _busy.add(template.key));
    try {
      await _assistants.createAssistant(AssistantDraft(
        name: template.name,
        emoji: template.emoji,
        instructions: template.instructions,
      ));
      _say('${template.name} added. Pick it at the top of Ask.');
      widget.onAssistantsChanged?.call();
      await _load();
    } catch (error) {
      _say(userMessage(error, 'Could not add ${template.name}.'));
    } finally {
      if (mounted) setState(() => _busy.remove(template.key));
    }
  }

  Future<void> _openRoutine(CatalogRoutine entry) async {
    final choice = await showModalBottomSheet<_RoutineChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RoutineSheet(entry: entry),
    );
    if (choice != null) await _toggleRoutine(entry, time: choice.time);
  }

  Future<void> _openAssistant(AssistantTemplate template) async {
    final add = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AssistantSheet(template: template, added: _hasAssistant(template)),
    );
    if (add == true) await _addAssistant(template);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Catalog',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: SegmentedButton<CatalogTab>(
            key: const Key('catalog-tab'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: CatalogTab.routines, label: Text('Routines')),
              ButtonSegment(value: CatalogTab.assistants, label: Text('Assistants')),
            ],
            selected: {_tab},
            onSelectionChanged: (selected) => setState(() => _tab = selected.first),
          ),
        ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(error, style: Theme.of(context).textTheme.bodyMedium),
          )
        else if (_catalog == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_tab == CatalogTab.routines)
          ..._routineSections()
        else
          ..._assistantRows(),
      ],
    );
  }

  List<Widget> _routineSections() {
    final groups = <String, List<CatalogRoutine>>{};
    for (final entry in _catalog!) {
      final heading = switch (entry.kind) {
        'after_conversation' => 'AFTER EACH CONVERSATION',
        'weekly' => 'EVERY WEEK',
        'monthly' => 'EVERY MONTH',
        _ => 'EVERY DAY',
      };
      groups.putIfAbsent(heading, () => []).add(entry);
    }
    return [
      for (final MapEntry(key: heading, value: entries) in groups.entries) ...[
        SettingsSection(heading),
        SettingsGroup(children: [
          for (final entry in entries)
            SettingsRow(
              key: Key('catalog-${entry.key}'),
              icon: Icons.schedule_rounded,
              leading: _Emoji(entry.emoji),
              title: entry.title,
              subtitle: '${entry.summary} · ${entry.scheduleText}',
              onTap: () => unawaited(_openRoutine(entry)),
              trailing: _AddButton(
                key: Key('catalog-add-${entry.key}'),
                added: entry.added,
                busy: _busy.contains(entry.key),
                onPressed: () => unawaited(_toggleRoutine(entry)),
              ),
            ),
        ]),
      ],
    ];
  }

  List<Widget> _assistantRows() => [
        const SettingsSection('READY TO USE'),
        SettingsGroup(children: [
          for (final template in _templates ?? const <AssistantTemplate>[])
            SettingsRow(
              key: Key('catalog-assistant-${template.key}'),
              icon: Icons.smart_toy_outlined,
              leading: _Emoji(template.emoji),
              title: template.name,
              subtitle: _firstSentence(template.instructions),
              onTap: () => unawaited(_openAssistant(template)),
              trailing: _AddButton(
                key: Key('catalog-add-assistant-${template.key}'),
                added: _hasAssistant(template),
                busy: _busy.contains(template.key),
                // Removing one is in Assistants: it has notes and chats of its own
                onPressed: _hasAssistant(template)
                    ? null
                    : () => unawaited(_addAssistant(template)),
              ),
            ),
        ]),
      ];
}

String _firstSentence(String text) {
  final end = text.indexOf('. ');
  return end < 0 ? text : text.substring(0, end + 1);
}

final class _Emoji extends StatelessWidget {
  const _Emoji(this.emoji);

  final String emoji;

  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: EchoPalette.of(context).accentSoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 16)),
      );
}

/// "Add", or "Added" (a tap removes a routine; an assistant is removed in Assistants).
final class _AddButton extends StatelessWidget {
  const _AddButton({required this.added, required this.busy, this.onPressed, super.key});

  final bool added;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    if (busy) {
      return const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (added) {
      return TextButton.icon(
        onPressed: onPressed,
        icon: Icon(Icons.check_rounded, size: 16, color: palette.green),
        label: Text('Added', style: TextStyle(color: palette.green)),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.accent,
        side: BorderSide(color: palette.accent),
        minimumSize: const Size(64, 34),
        visualDensity: VisualDensity.compact,
      ),
      child: const Text('Add'),
    );
  }
}

final class _RoutineChoice {
  const _RoutineChoice(this.time);

  final String? time;
}

/// One routine before adding it: what it does, what it could say, when.
final class _RoutineSheet extends StatefulWidget {
  const _RoutineSheet({required this.entry});

  final CatalogRoutine entry;

  @override
  State<_RoutineSheet> createState() => _RoutineSheetState();
}

final class _RoutineSheetState extends State<_RoutineSheet> {
  late String _time = widget.entry.time;

  Future<void> _pickTime() async {
    final parts = _time.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (picked != null && mounted) {
      setState(() => _time =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              _Emoji(entry.emoji),
              const SizedBox(width: 12),
              Expanded(child: Text(entry.title, style: textTheme.titleLarge)),
            ]),
            const SizedBox(height: 12),
            Text(entry.instruction, style: textTheme.bodyMedium),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.background,
                borderRadius: BorderRadius.circular(AppTheme.tileRadius),
                border: Border(left: BorderSide(color: palette.accent, width: 3)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('FOR EXAMPLE', style: textTheme.labelSmall?.copyWith(color: palette.text2)),
                const SizedBox(height: 4),
                Text(entry.example, style: textTheme.bodySmall?.copyWith(color: palette.text)),
              ]),
            ),
            const SizedBox(height: 14),
            ListTile(
              key: const Key('catalog-time'),
              contentPadding: EdgeInsets.zero,
              title: const Text('When'),
              subtitle: Text(entry.scheduleText),
              trailing: entry.afterConversation
                  ? null
                  : entry.added
                      ? Text(_time)
                      : TextButton(onPressed: _pickTime, child: Text('$_time ›')),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Uses'),
              trailing: Text('Your memory only', style: textTheme.bodySmall),
            ),
            const SizedBox(height: 8),
            if (entry.added)
              OutlinedButton(
                key: const Key('catalog-sheet-remove'),
                onPressed: () => Navigator.pop(context, const _RoutineChoice(null)),
                child: const Text('Remove routine'),
              )
            else
              FilledButton(
                key: const Key('catalog-sheet-add'),
                onPressed: () => Navigator.pop(
                    context, _RoutineChoice(_time == entry.time ? null : _time)),
                child: const Text('Add routine'),
              ),
            const SizedBox(height: 8),
            Text(
              'It becomes one of your routines: change or remove it in Settings → Routines.',
              style: textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// One assistant before adding it: its instructions, as it will start.
final class _AssistantSheet extends StatelessWidget {
  const _AssistantSheet({required this.template, required this.added});

  final AssistantTemplate template;
  final bool added;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              _Emoji(template.emoji),
              const SizedBox(width: 12),
              Expanded(child: Text(template.name, style: textTheme.titleLarge)),
            ]),
            const SizedBox(height: 12),
            Text(template.instructions, style: textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('catalog-sheet-add-assistant'),
              onPressed: added ? null : () => Navigator.pop(context, true),
              child: Text(added ? 'Already added' : 'Add assistant'),
            ),
            const SizedBox(height: 8),
            Text(
              'Pick it at the top of Ask. Change its instructions in Settings → Assistants.',
              style: textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
