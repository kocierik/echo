import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import '../../models/memory_items.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/assistants_api.dart';
import '../../services/api/memory_items_api.dart';
import '../../theme/app_theme.dart';
import 'settings_components.dart';

/// One assistant: its name and emoji, instructions, notes and documents; a new one starts
/// from [template]. Pops true once something was saved or deleted.
final class AssistantEditorScreen extends StatefulWidget {
  const AssistantEditorScreen({
    required this.api,
    required this.documents,
    this.assistant,
    this.template,
    super.key,
  });

  final AssistantsApi api;
  final DocumentsApi documents;

  /// The one being edited; null: a new one.
  final Assistant? assistant;
  final AssistantTemplate? template;

  @override
  State<AssistantEditorScreen> createState() => _AssistantEditorScreenState();
}

final class _AssistantEditorScreenState extends State<AssistantEditorScreen> {
  late final _emoji = TextEditingController(
    text: widget.assistant?.emoji ?? widget.template?.emoji ?? '🤖',
  );
  late final _name = TextEditingController(
    text: widget.assistant?.name ?? widget.template?.name ?? '',
  );
  late final _instructions = TextEditingController(
    text: widget.assistant?.instructions ?? widget.template?.instructions ?? '',
  );
  late final _notes = TextEditingController(text: widget.assistant?.notes ?? '');
  late final Set<String> _chosen = {...?widget.assistant?.documentIds};
  List<UserDocument>? _documents;

  /// The documents could not be listed: the chosen ones are kept as they were.
  bool _documentsUnknown = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDocuments());
  }

  @override
  void dispose() {
    _emoji.dispose();
    _name.dispose();
    _instructions.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadDocuments() async {
    try {
      final documents = await widget.documents.listDocuments();
      if (mounted) setState(() => _documents = documents);
    } catch (_) {
      if (mounted) {
        setState(() {
          _documents = const [];
          _documentsUnknown = true;
        });
      }
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final instructions = _instructions.text.trim();
    if (name.isEmpty || instructions.isEmpty) {
      setState(() => _error = 'Give it a name and instructions.');
      return;
    }
    final draft = AssistantDraft(
      name: name,
      emoji: _emoji.text.trim().isEmpty ? '🤖' : _emoji.text.trim(),
      instructions: instructions,
      notes: _notes.text.trim(),
      // Documents deleted since were chosen once: kept only if still there
      documentIds: _documents == null || _documentsUnknown
          ? _chosen.toList()
          : [
              for (final document in _documents!)
                if (_chosen.contains(document.id)) document.id,
            ],
    );
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final assistant = widget.assistant;
      if (assistant == null) {
        await widget.api.createAssistant(draft);
      } else {
        await widget.api.updateAssistant(assistant.id, draft);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userMessage(error, 'Could not save it.');
        });
      }
    }
  }

  Future<void> _delete() async {
    final assistant = widget.assistant!;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${assistant.name}?'),
        content: const Text('Its chats and routines stay, with Echo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.deleteAssistant(assistant.id);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userMessage(error, 'Could not delete it.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final documents = _documents;
    final hint = textTheme.bodySmall?.copyWith(color: palette.text2);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        title: Text(widget.assistant == null ? 'New assistant' : 'Edit assistant'),
        actions: [
          TextButton(
            key: const Key('assistant-save'),
            onPressed: _saving ? null : () => unawaited(_save()),
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                child: TextField(
                  key: const Key('assistant-emoji'),
                  controller: _emoji,
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const Key('assistant-name'),
                  controller: _name,
                  maxLength: Assistant.maxName,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('assistant-instructions'),
            controller: _instructions,
            minLines: 4,
            maxLines: 10,
            maxLength: Assistant.maxInstructions,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Instructions',
              hintText: 'Its role, its tone, what to watch for.',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('assistant-notes'),
            controller: _notes,
            minLines: 3,
            maxLines: 10,
            maxLength: Assistant.maxNotes,
            decoration: const InputDecoration(
              labelText: 'Notes',
              hintText: '- Vegetarian\n- Breakfast at 7',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          Text(
            'What it keeps in mind about its topic. It adds and removes lines itself when '
            'you tell it something worth keeping.',
            style: hint,
          ),
          const SizedBox(height: 20),
          Text('DOCUMENTS', style: textTheme.labelMedium?.copyWith(color: palette.text2)),
          const SizedBox(height: 4),
          Text('None chosen: it searches all of your documents.', style: hint),
          if (documents == null)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (documents.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _documentsUnknown
                    ? 'Could not load your documents.'
                    : 'No documents yet: add them in Profile → Memory.',
                style: hint,
              ),
            )
          else
            for (final document in documents)
              CheckboxListTile(
                key: Key('assistant-document-${document.id}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _chosen.contains(document.id),
                title: Text(document.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                onChanged: (chosen) => setState(() {
                  if (chosen == true) {
                    _chosen.add(document.id);
                  } else {
                    _chosen.remove(document.id);
                  }
                }),
              ),
          if (_error != null) SettingsMessage(_error!, error: true),
          if (widget.assistant != null) ...[
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('assistant-delete'),
                onPressed: _saving ? null : () => unawaited(_delete()),
                style: TextButton.styleFrom(foregroundColor: palette.red),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Delete assistant'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
