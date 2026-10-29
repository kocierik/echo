import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/assistants_api.dart';
import '../../services/api/memory_items_api.dart';
import '../../theme/app_theme.dart';
import 'assistant_editor_screen.dart';
import 'settings_components.dart';

/// Profile → Assistants: Echo focused on one part of the user's life (work, diet,
/// sleep…), each with its instructions, notes and documents; chatted with in Ask.
final class AssistantsScreen extends StatefulWidget {
  const AssistantsScreen({required this.api, required this.documents, super.key});

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

  Future<void> _open({Assistant? assistant, AssistantTemplate? template}) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantEditorScreen(
          api: widget.api,
          documents: widget.documents,
          assistant: assistant,
          template: template,
        ),
      ),
    );
    if (changed == true) await _load();
  }

  /// "New assistant": a template to start from, or a blank one.
  Future<void> _new() async {
    setState(() => _error = null);
    final List<AssistantTemplate> templates;
    try {
      templates = await widget.api.assistantTemplates();
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'Could not load the templates.'));
      return;
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<AssistantTemplate>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final template in templates)
              ListTile(
                key: Key('assistant-template-${template.key}'),
                leading: Text(template.emoji, style: const TextStyle(fontSize: 24)),
                title: Text(template.name),
                onTap: () => Navigator.pop(context, template),
              ),
            ListTile(
              key: const Key('assistant-template-blank'),
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Start from scratch'),
              onTap: () => Navigator.pop(
                context,
                const AssistantTemplate(key: '', name: '', emoji: '🤖', instructions: ''),
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) await _open(template: chosen);
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
