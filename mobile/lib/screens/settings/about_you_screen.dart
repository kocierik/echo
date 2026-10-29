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

  /// "Add a fact" or editing one: the sentence, in a dialog.
  Future<String?> _ask({String? initial}) => showDialog<String>(
        context: context,
        builder: (context) => _FactDialog(initial: initial),
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
          const Center(child: CircularProgressIndicator())
        else if (facts != null) ...[
          if (facts.suggestions.isNotEmpty) ...[
            const SettingsSection('ECHO NOTICED'),
            for (final fact in facts.suggestions)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(fact.text, style: textTheme.bodyMedium),
                          Text(
                            fact.source == 'conversation'
                                ? 'Heard in a conversation'
                                : 'From a request to Echo',
                            style: textTheme.bodySmall?.copyWith(color: palette.text2),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      key: Key('fact-keep-${fact.id}'),
                      onPressed: () => unawaited(
                        _act(() => widget.api.keepFact(fact.id), 'Could not keep it.'),
                      ),
                      child: const Text('Keep'),
                    ),
                    IconButton(
                      key: Key('fact-discard-${fact.id}'),
                      tooltip: 'Discard',
                      onPressed: () => unawaited(
                        _act(() => widget.api.deleteFact(fact.id), 'Could not discard it.'),
                      ),
                      icon: Icon(Icons.close_rounded, color: palette.text2),
                    ),
                  ],
                ),
              ),
          ],
          const SettingsSection('ABOUT YOU'),
          if (facts.kept.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                'Nothing yet. Add a fact, or say "Echo, ricordati che…".',
                style: textTheme.bodyMedium?.copyWith(color: palette.text2),
              ),
            ),
          for (final fact in facts.kept)
            InkWell(
              key: Key('fact-${fact.id}'),
              onTap: () => unawaited(_edit(fact)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(fact.text, style: textTheme.bodyMedium)),
                    IconButton(
                      key: Key('fact-delete-${fact.id}'),
                      tooltip: 'Delete',
                      onPressed: () => unawaited(
                        _act(() => widget.api.deleteFact(fact.id), 'Could not delete it.'),
                      ),
                      icon: Icon(Icons.delete_outline_rounded, color: palette.text2),
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: TextButton.icon(
                key: const Key('facts-add'),
                onPressed: () => unawaited(_add()),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add a fact'),
              ),
            ),
          ),
        ],
        if (_error != null) SettingsMessage(_error!, error: true),
      ],
    );
  }
}

/// The sentence of a fact; its controller lives as long as the dialog, closing included.
final class _FactDialog extends StatefulWidget {
  const _FactDialog({this.initial});

  final String? initial;

  @override
  State<_FactDialog> createState() => _FactDialogState();
}

final class _FactDialogState extends State<_FactDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add a fact' : 'Edit'),
      content: TextField(
        key: const Key('fact-text'),
        controller: _text,
        autofocus: true,
        maxLength: 200,
        maxLines: 3,
        minLines: 1,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Lavoro come sviluppatore a Milano'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(context, _text.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
