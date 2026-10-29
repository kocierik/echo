import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/memory_items.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/memory_items_api.dart';
import '../../theme/app_theme.dart';
import 'settings_components.dart';

/// A file the user picked: its name and contents.
typedef PickedDocument = ({String name, List<int> bytes});

/// The phone's file picker, for PDF, Word, text and Markdown; null when cancelled.
Future<PickedDocument?> pickDocument() async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['pdf', 'docx', 'txt', 'md'],
  );
  if (files.isEmpty) return null;
  final file = files.first;
  return (name: file.name, bytes: await file.xFile.readAsBytes());
}

/// "Ready · 12 pages", "Reading it…", "Failed: …".
String documentStateText(UserDocument document) => switch (document.status) {
      'processing' => 'Reading it…',
      'failed' => 'Failed: ${document.error ?? 'try again'}',
      _ => document.pages != null
          ? 'Ready · ${document.pages} pages'
          : 'Ready · ${document.wordCount} words',
    };

/// Profile → Memory → Documents: files whose text Echo searches when it answers (it keeps
/// the text, never the file).
final class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({
    required this.api,
    this.pick = pickDocument,
    this.pollInterval = const Duration(seconds: 3),
    super.key,
  });

  final DocumentsApi api;
  final Future<PickedDocument?> Function() pick;

  /// While a document is being read: how often to check.
  final Duration pollInterval;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

final class _DocumentsScreenState extends State<DocumentsScreen> {
  List<UserDocument>? _documents;
  String? _error;
  bool _adding = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _poll?.cancel();
    try {
      final documents = await widget.api.listDocuments();
      if (!mounted) return;
      setState(() => _documents = documents);
    } catch (error) {
      if (mounted && _documents == null) {
        setState(() => _error = userMessage(error, 'Could not load your documents.'));
      }
    }
    // Keep checking while one is being read, also after a failed check
    if (mounted && (_documents ?? const []).any((d) => d.isProcessing)) {
      _poll = Timer(widget.pollInterval, () => unawaited(_load()));
    }
  }

  Future<void> _add() async {
    if (_adding) return;
    final PickedDocument? picked;
    try {
      picked = await widget.pick();
    } catch (_) {
      setState(() => _error = 'Could not open the file.');
      return;
    }
    if (picked == null || !mounted) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await widget.api.uploadDocument(picked.name, picked.bytes);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = userMessage(error, 'Could not add it.'));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _open(UserDocument document) async {
    final deleted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _DocumentSheet(api: widget.api, document: document),
    );
    if (deleted == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final documents = _documents;
    return SettingsPageScaffold(
      title: 'Documents',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'Echo searches these when it answers you and names the document it used. It '
            'keeps their text, never the file. PDF, Word, text or Markdown, up to 10 MB.',
            style: textTheme.bodyMedium?.copyWith(color: palette.text2),
          ),
        ),
        if (documents == null && _error == null)
          const Center(child: CircularProgressIndicator())
        else if (documents != null) ...[
          if (documents.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                'No documents yet.',
                style: textTheme.bodyMedium?.copyWith(color: palette.text2),
              ),
            ),
          for (final document in documents)
            SettingsRow(
              key: Key('document-${document.id}'),
              icon: Icons.description_outlined,
              title: document.title,
              subtitle: documentStateText(document),
              onTap: () => unawaited(_open(document)),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: TextButton.icon(
                key: const Key('documents-add'),
                onPressed: _adding ? null : () => unawaited(_add()),
                icon: const Icon(Icons.upload_file_rounded),
                label: Text(_adding ? 'Adding…' : 'Add a document'),
              ),
            ),
          ),
        ],
        if (_error != null) SettingsMessage(_error!, error: true),
      ],
    );
  }
}

/// A document: its state, the beginning of its text, Delete.
final class _DocumentSheet extends StatefulWidget {
  const _DocumentSheet({required this.api, required this.document});

  final DocumentsApi api;
  final UserDocument document;

  @override
  State<_DocumentSheet> createState() => _DocumentSheetState();
}

final class _DocumentSheetState extends State<_DocumentSheet> {
  String? _preview;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      try {
        final full = await widget.api.getDocument(widget.document.id);
        if (mounted) setState(() => _preview = full.preview);
      } catch (_) {}
    }());
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this document?'),
        content: const Text('Echo stops using it in its answers.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await widget.api.deleteDocument(widget.document.id);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not delete it.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final document = widget.document;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(document.title, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            documentStateText(document),
            style: textTheme.bodySmall?.copyWith(color: palette.text2),
          ),
          if (_preview != null) ...[
            const SizedBox(height: 12),
            Text(_preview!, style: textTheme.bodyMedium, maxLines: 12),
          ],
          const SizedBox(height: 12),
          TextButton.icon(
            key: const Key('document-delete'),
            onPressed: () => unawaited(_delete()),
            icon: Icon(Icons.delete_outline_rounded, color: palette.red),
            label: Text('Delete', style: TextStyle(color: palette.red)),
          ),
        ],
      ),
    );
  }
}
