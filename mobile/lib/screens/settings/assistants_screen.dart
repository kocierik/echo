import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/assistants_api.dart';
import '../../services/api/memory_items_api.dart';
import '../../theme/app_theme.dart';
import 'assistant_create_screen.dart';
import 'assistant_editor_screen.dart';
import 'settings_components.dart';

/// Profile → Assistants: Echo focused on one part of the user's life (work, diet,
/// sleep…), each with its instructions, notes and documents; chatted with in Ask.
final class AssistantsScreen extends StatefulWidget {
  const AssistantsScreen({
    required this.api,
    required this.documents,
    this.onChanged,
    super.key,
  });

  /// One was made, changed or deleted (Ask's row reloads).
  final VoidCallback? onChanged;

  final AssistantsApi api;

  /// The documents an assistant may be given.
  final DocumentsApi documents;

  @override
  State<AssistantsScreen> createState() => _AssistantsScreenState();
}

final class _AssistantsScreenState extends State<AssistantsScreen> {
  List<Assistant>? _assistants;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final assistants = await widget.api.listAssistants();
      if (mounted) setState(() => _assistants = assistants);
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'Could not load your assistants.'));
    }
  }

  Future<void> _open({required Assistant assistant}) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantEditorScreen(
          api: widget.api,
          documents: widget.documents,
          assistant: assistant,
        ),
      ),
    );
    if (changed == true) {
      widget.onChanged?.call();
      await _load();
    }
  }

  /// "New assistant": a template to start from, or a blank one.
  /// "New assistant": described in words, written by Echo, tried, then saved.
  Future<void> _new() async {
    setState(() => _error = null);
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantCreateScreen(api: widget.api, documents: widget.documents),
      ),
    );
    if (saved == true && mounted) {
      widget.onChanged?.call();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final assistants = _assistants;
    final full = assistants != null && assistants.length >= Assistant.maxCount;
    return SettingsPageScaffold(
      title: 'Assistants',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'Echo focused on one part of your life: its own way of answering, what it '
            'keeps in mind about it, and the documents that matter there. Start a chat '
            'with one from Ask.',
            style: textTheme.bodyMedium?.copyWith(color: palette.text2),
          ),
        ),
        if (assistants == null && _error == null)
          const Center(child: CircularProgressIndicator())
        else if (assistants != null) ...[
          if (assistants.isEmpty)
            Padding(
              key: const Key('assistants-empty'),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                'None yet. Start from work, diet or sleep, or make your own.',
                style: textTheme.bodyMedium?.copyWith(color: palette.text2),
              ),
            ),
          for (final assistant in assistants)
            SettingsRow(
              key: Key('assistant-${assistant.id}'),
              icon: Icons.smart_toy_outlined,
              leading: Text(assistant.emoji, style: const TextStyle(fontSize: 22)),
              title: assistant.name,
              subtitle: assistant.notes.isEmpty
                  ? 'No notes yet'
                  : '${assistant.notes.split('\n').length} notes',
              onTap: () => unawaited(_open(assistant: assistant)),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: TextButton.icon(
                key: const Key('assistants-new'),
                onPressed: full ? null : () => unawaited(_new()),
                icon: const Icon(Icons.add_rounded),
                label: Text(full ? 'At most ${Assistant.maxCount} assistants' : 'New assistant'),
              ),
            ),
          ),
        ],
        if (_error != null) SettingsMessage(_error!, error: true),
      ],
    );
  }
}
