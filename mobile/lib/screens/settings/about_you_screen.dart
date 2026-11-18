import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/memory_items.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/memory_items_api.dart';
import '../../theme/app_theme.dart';
import 'settings_components.dart';

/// Profile → Memory → About you: the facts Echo uses in every answer, and the ones it
/// noticed in conversations (used only once kept).
final class AboutYouScreen extends StatefulWidget {
  const AboutYouScreen({required this.api, super.key});

  final AboutYouApi api;

  @override
  State<AboutYouScreen> createState() => _AboutYouScreenState();
}

final class _AboutYouScreenState extends State<AboutYouScreen> {
  UserFacts? _facts;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final facts = await widget.api.getFacts();
      if (mounted) setState(() => _facts = facts);
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'Could not load what Echo knows.'));
    }
  }

  Future<void> _act(Future<void> Function() action, String failure) async {
    setState(() => _error = null);
    try {
      await action();
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, failure));
    }
  }

  /// "Add a fact" or editing one: the sentence, in a sheet from the bottom.
  Future<String?> _ask({String? initial}) => showModalBottomSheet<String>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _FactSheet(initial: initial),
      );

  Future<void> _add() async {
    final text = await _ask();
    if (text == null || text.isEmpty) return;
    await _act(() => widget.api.addFact(text), 'Could not add it.');
  }

  Future<void> _edit(UserFact fact) async {
    final text = await _ask(initial: fact.text);
    if (text == null || text.isEmpty || text == fact.text) return;
    await _act(() => widget.api.editFact(fact.id, text), 'Could not change it.');
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final facts = _facts;
    return SettingsPageScaffold(
      title: 'About you',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'Echo uses these in every answer. It suggests new ones from what you say; '
            'nothing is used before you keep it.',
            style: textTheme.bodyMedium?.copyWith(color: palette.text2),
          ),
        ),
        if (facts == null && _error == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (facts != null) ...[
          if (facts.suggestions.isNotEmpty) ...[
            SettingsSection('ECHO NOTICED · ${facts.suggestions.length}'),
            Container(
              key: const Key('facts-suggestions'),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: palette.accentSoft,
                borderRadius: BorderRadius.circular(AppTheme.panelRadius),
              ),
              child: Column(
                children: [
                  for (final (index, fact) in facts.suggestions.indexed) ...[
                    if (index > 0)
                      Divider(height: 1, indent: 60, color: palette.onAccentSoft.withValues(alpha: 0.15)),
                    _SuggestionRow(
                      fact: fact,
                      onKeep: () => unawaited(
                        _act(() => widget.api.keepFact(fact.id), 'Could not keep it.'),
                      ),
                      onDiscard: () => unawaited(
                        _act(() => widget.api.deleteFact(fact.id), 'Could not discard it.'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          SettingsSection(
            facts.kept.isEmpty ? 'ABOUT YOU' : 'ABOUT YOU · ${facts.kept.length}',
          ),
          SettingsGroup(children: [
            if (facts.kept.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Text(
                  'Nothing yet. Add a fact, or say "Echo, ricordati che…".',
                  style: textTheme.bodyMedium?.copyWith(color: palette.text2),
                ),
              ),
            for (final fact in facts.kept)
              _FactRow(
                key: Key('fact-${fact.id}'),
                fact: fact,
                onEdit: () => unawaited(_edit(fact)),
                onDelete: () => unawaited(
                  _act(() => widget.api.deleteFact(fact.id), 'Could not delete it.'),
                ),
              ),
            InkWell(
              key: const Key('facts-add'),
              onTap: () => unawaited(_add()),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Row(
                  children: [
                    _Badge(icon: Icons.add_rounded, color: palette.accent, filled: true),
                    const SizedBox(width: 14),
                    Text(
                      'Add a fact',
                      style: textTheme.bodyMedium?.copyWith(
                        color: palette.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ]),
        ],
        if (_error != null) SettingsMessage(_error!, error: true),
      ],
    );
  }
}

/// A round icon at the start of a row.
final class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color, this.filled = false});

  final IconData icon;
  final Color color;

  /// The color as background (Add), or a soft tint of it.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 18, color: filled ? palette.background : color),
    );
  }
}

/// A kept fact: a tap edits it.
final class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.fact,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  final UserFact fact;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          children: [
            _Badge(icon: Icons.person_outline_rounded, color: palette.accent),
            const SizedBox(width: 14),
            Expanded(child: Text(fact.text, style: textTheme.bodyMedium)),
            IconButton(
              key: Key('fact-delete-${fact.id}'),
              tooltip: 'Delete',
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline_rounded, size: 20, color: palette.text2),
            ),
          ],
        ),
      ),
    );
  }
}

/// What Echo noticed: Keep, or discard.
final class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.fact,
    required this.onKeep,
    required this.onDiscard,
  });

  final UserFact fact;
  final VoidCallback onKeep;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      child: Row(
        children: [
          _Badge(icon: Icons.lightbulb_outline_rounded, color: palette.onAccentSoft),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fact.text,
                  style: textTheme.bodyMedium?.copyWith(color: palette.onAccentSoft),
                ),
                const SizedBox(height: 2),
                Text(
                  fact.source == 'conversation'
                      ? 'Heard in a conversation'
                      : 'From a request to Echo',
                  style: textTheme.bodySmall?.copyWith(
                    color: palette.onAccentSoft.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: Key('fact-keep-${fact.id}'),
            onPressed: onKeep,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Keep'),
          ),
          IconButton(
            key: Key('fact-discard-${fact.id}'),
            tooltip: 'Discard',
            onPressed: onDiscard,
            icon: Icon(Icons.close_rounded, size: 20, color: palette.onAccentSoft),
          ),
        ],
      ),
    );
  }
}

/// The sentence of a fact; its controller lives as long as the sheet, closing included.
final class _FactSheet extends StatefulWidget {
  const _FactSheet({this.initial});

  final String? initial;

  @override
  State<_FactSheet> createState() => _FactSheetState();
}

final class _FactSheetState extends State<_FactSheet> {
  late final _text = TextEditingController(text: widget.initial)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final text = _text.text.trim();
    if (text.isNotEmpty) Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final field = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: palette.border),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.initial == null ? 'Add a fact' : 'Edit the fact',
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'One sentence about you: Echo keeps it in mind in every answer.',
            style: textTheme.bodySmall?.copyWith(color: palette.text2),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('fact-text'),
            controller: _text,
            autofocus: true,
            maxLength: 200,
            minLines: 3,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Lavoro come sviluppatore a Milano',
              contentPadding: const EdgeInsets.all(16),
              border: field,
              enabledBorder: field,
              focusedBorder: field.copyWith(
                borderSide: BorderSide(color: palette.accent, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('fact-save'),
            onPressed: _text.text.trim().isEmpty ? null : _save,
            child: const Text('Save'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
